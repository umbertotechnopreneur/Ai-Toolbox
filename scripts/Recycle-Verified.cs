// Runtime-only Windows Shell bridge. This source is not compiled during setup/editing.
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.Win32.SafeHandles;

namespace PhotoCleanup {
    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IShellItem {
        void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint kind, out IntPtr name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }

    // Exact SDK method order is required even for slots never called by this bridge.
    [ComImport, Guid("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IFileOperation {
        void Advise(IProgressSink sink, out uint cookie);
        void Unadvise(uint cookie);
        void SetOperationFlags(uint flags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string text);
        void SetProgressDialog(IntPtr dialog);
        void SetProperties(IntPtr properties);
        void SetOwnerWindow(IntPtr window);
        void ApplyPropertiesToItem(IShellItem item);
        void ApplyPropertiesToItems(IntPtr items);
        void RenameItem(IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name, IProgressSink sink);
        void RenameItems(IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void MoveItem(IShellItem item, IShellItem folder, [MarshalAs(UnmanagedType.LPWStr)] string name, IProgressSink sink);
        void MoveItems(IntPtr items, IShellItem folder);
        void CopyItem(IShellItem item, IShellItem folder, [MarshalAs(UnmanagedType.LPWStr)] string name, IProgressSink sink);
        void CopyItems(IntPtr items, IShellItem folder);
        void DeleteItem(IShellItem item, IProgressSink sink);
        void DeleteItems(IntPtr items);
        void NewItem(IShellItem folder, uint attributes, [MarshalAs(UnmanagedType.LPWStr)] string name,
                     [MarshalAs(UnmanagedType.LPWStr)] string template, IProgressSink sink);
        void PerformOperations();
        void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }

    [ComVisible(true), Guid("04b0f1a7-9490-44bc-96e1-4296a31252e2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IProgressSink {
        [PreserveSig] int StartOperations();
        [PreserveSig] int FinishOperations(int result);
        [PreserveSig] int PreRenameItem(uint flags, IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostRenameItem(uint flags, IShellItem item, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem created);
        [PreserveSig] int PreMoveItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostMoveItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem created);
        [PreserveSig] int PreCopyItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostCopyItem(uint flags, IShellItem item, IShellItem destination, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IShellItem created);
        [PreserveSig] int PreDeleteItem(uint flags, IShellItem item);
        [PreserveSig] int PostDeleteItem(uint flags, IShellItem item, int result, IShellItem created);
        [PreserveSig] int PreNewItem(uint flags, IShellItem folder, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostNewItem(uint flags, IShellItem folder, [MarshalAs(UnmanagedType.LPWStr)] string name,
                                    [MarshalAs(UnmanagedType.LPWStr)] string template, uint attributes, int result, IShellItem created);
        [PreserveSig] int UpdateProgress(uint total, uint done);
        [PreserveSig] int ResetTimer();
        [PreserveSig] int PauseTimer();
        [PreserveSig] int ResumeTimer();
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FileInformation {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class RecycleSink : IProgressSink {
        public string RecyclePath;
        public int Result = unchecked((int)0x80004004);
        private readonly string source;
        private readonly FileInformation identity;

        // sourcePath: Individually approved file, never a directory or glob.
        // fileIdentity: Identity of the source handle held while recycling.
        public RecycleSink(string sourcePath, FileInformation fileIdentity) { source = sourcePath; identity = fileIdentity; }

        // flags: Windows transfer flags, which must request recycling.
        // item: Shell item queued for the approved source.
        // Exception: Failures become E_ABORT, before any delete is attempted.
        public int PreDeleteItem(uint flags, IShellItem item) {
            try {
                if ((flags & 0x80) == 0 || !Native.SameIdentity(source, identity)) { return unchecked((int)0x80004004); }
                IntPtr display;
                item.GetDisplayName(0x80058000, out display); // SIGDN_FILESYSPATH
                try {
                    if (!String.Equals(Path.GetFullPath(Marshal.PtrToStringUni(display)), source, StringComparison.OrdinalIgnoreCase)) {
                        return unchecked((int)0x80004004);
                    }
                } finally { Marshal.FreeCoTaskMem(display); }
                return 0;
            } catch { return unchecked((int)0x80004004); }
        }

        // flags: Transfer flags received from Windows.
        // item: Original Shell item.
        // result: Individual delete HRESULT.
        // created: Newly created Recycle Bin item; null is not accepted as a receipt.
        public int PostDeleteItem(uint flags, IShellItem item, int result, IShellItem created) {
            Result = result;
            if (result >= 0 && created != null) {
                IntPtr display;
                created.GetDisplayName(0x80058000, out display);
                try { RecyclePath = Marshal.PtrToStringUni(display); }
                finally { Marshal.FreeCoTaskMem(display); }
            }
            return 0;
        }

        public int StartOperations() { return 0; }
        // result: Overall Shell HRESULT.
        public int FinishOperations(int result) { return 0; }
        // flags: Unused flags; rename operations are never queued.
        // item: Unused item.
        // name: Unused destination name.
        public int PreRenameItem(uint flags, IShellItem item, string name) { return unchecked((int)0x80004004); }
        // flags: Unused flags.
        // item: Unused item.
        // name: Unused name.
        // result: Unused result.
        // created: Unused new item.
        public int PostRenameItem(uint flags, IShellItem item, string name, int result, IShellItem created) { return 0; }
        // flags: Unused flags; move operations are never queued.
        // item: Unused source.
        // destination: Unused folder.
        // name: Unused new name.
        public int PreMoveItem(uint flags, IShellItem item, IShellItem destination, string name) { return unchecked((int)0x80004004); }
        // flags: Unused flags.
        // item: Unused source.
        // destination: Unused folder.
        // name: Unused new name.
        // result: Unused result.
        // created: Unused new item.
        public int PostMoveItem(uint flags, IShellItem item, IShellItem destination, string name, int result, IShellItem created) { return 0; }
        // flags: Unused flags; copy operations are never queued.
        // item: Unused source.
        // destination: Unused folder.
        // name: Unused new name.
        public int PreCopyItem(uint flags, IShellItem item, IShellItem destination, string name) { return unchecked((int)0x80004004); }
        // flags: Unused flags.
        // item: Unused source.
        // destination: Unused folder.
        // name: Unused new name.
        // result: Unused result.
        // created: Unused new item.
        public int PostCopyItem(uint flags, IShellItem item, IShellItem destination, string name, int result, IShellItem created) { return 0; }
        // flags: Unused flags; folder/file creation is never queued.
        // folder: Unused folder.
        // name: Unused name.
        public int PreNewItem(uint flags, IShellItem folder, string name) { return unchecked((int)0x80004004); }
        // flags: Unused flags.
        // folder: Unused folder.
        // name: Unused name.
        // template: Unused template.
        // attributes: Unused attributes.
        // result: Unused result.
        // created: Unused new item.
        public int PostNewItem(uint flags, IShellItem folder, string name, string template, uint attributes, int result, IShellItem created) { return 0; }
        // total: Shell work total.
        // done: Shell work completed.
        public int UpdateProgress(uint total, uint done) { return 0; }
        public int ResetTimer() { return 0; }
        public int PauseTimer() { return 0; }
        public int ResumeTimer() { return 0; }
    }

    public static class Native {
        // handle: File handle whose identity must be read without touching content.
        // information: File-system identity returned by Windows.
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInformation information);
        // path: Absolute disk file for a Shell item.
        // binding: No custom binding context is used.
        // iid: IShellItem interface ID.
        // item: Newly created Shell item.
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(string path, IntPtr binding, ref Guid iid, out IShellItem item);

        // path: Current source path to compare with the held source file.
        // expected: Previously read file identity.
        // Exception: I/O failures are handled by the progress sink and abort deletion.
        public static bool SameIdentity(string path, FileInformation expected) {
            using (FileStream file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete)) {
                FileInformation current;
                return GetFileInformationByHandle(file.SafeFileHandle, out current) && current.Volume == expected.Volume &&
                    current.IndexHigh == expected.IndexHigh && current.IndexLow == expected.IndexLow;
            }
        }

        // path: One absolute approved file path, never recursive or wildcard-based.
        // root: Approved input directory, separate from the retained target.
        // expectedHash: SHA-256 freshly verified against the locked retained copy.
        // Exception: Invalid scopes, network/removable sources, changed files or Shell failures abort.
        public static string Recycle(string path, string root, string expectedHash) {
            path = Path.GetFullPath(path);
            root = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!path.StartsWith(root, StringComparison.OrdinalIgnoreCase) || !File.Exists(path) || Directory.Exists(path)) {
                throw new IOException("Not a regular file in the approved source.");
            }
            DriveInfo drive = new DriveInfo(Path.GetPathRoot(path));
            if (drive.DriveType != DriveType.Fixed) { throw new IOException("A local fixed drive is required for recycling."); }
            using (FileStream source = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete)) {
                using (SHA256 sha = SHA256.Create()) {
                    string digest = BitConverter.ToString(sha.ComputeHash(source)).Replace("-", "").ToLowerInvariant();
                    if (!String.Equals(digest, expectedHash, StringComparison.Ordinal)) { throw new IOException("Source content changed before recycling."); }
                }
                FileInformation identity;
                if (!GetFileInformationByHandle(source.SafeFileHandle, out identity)) { throw new IOException("Cannot verify source identity."); }
                IFileOperation operation = null;
                IShellItem item = null;
                try {
                    operation = (IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("3ad05575-8857-4850-9277-11b85bdb8e09")));
                    // Never accept permanent deletion, recursion or connected-file deletion.
                    // WANTNUKEWARNING overrides automatic confirmation for destructive Shell warnings.
                    operation.SetOperationFlags(0x00080000 | 0x00100000 | 0x20000000 | 0x0040 | 0x0400 | 0x1000 | 0x2000 | 0x0004 | 0x0010 | 0x4000);
                    Guid iid = typeof(IShellItem).GUID;
                    SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out item);
                    RecycleSink sink = new RecycleSink(path, identity);
                    operation.DeleteItem(item, sink);
                    operation.PerformOperations();
                    bool aborted;
                    operation.GetAnyOperationsAborted(out aborted);
                    if (aborted || sink.Result < 0 || String.IsNullOrEmpty(sink.RecyclePath) || File.Exists(path)) {
                        throw new IOException("Recycling was not confirmed. Inspect the source and operation log.");
                    }
                    return sink.RecyclePath;
                } finally {
                    if (item != null) { Marshal.FinalReleaseComObject(item); }
                    if (operation != null) { Marshal.FinalReleaseComObject(operation); }
                }
            }
        }
    }
}
