#requires -Version 5.1
# UiSmokeTest: Render the interface and exit without accessing a source or worker.
[CmdletBinding()]
param(
    [switch]$UiSmokeTest,
    [switch]$WorkflowSmokeTest,
    [switch]$DialogSmokeTest
)

if (@(@($UiSmokeTest, $WorkflowSmokeTest, $DialogSmokeTest) | Where-Object { [bool]$_ }).Count -gt 1) { throw 'Scegli un solo tipo di test.' }

$ErrorActionPreference = 'Stop'
$script:appRoot = $PSScriptRoot
Set-StrictMode -Version 2.0

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    throw 'Avvia Photo-Organizer.cmd oppure powershell.exe -STA -File Photo-Organizer.ps1.'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# No PowerShell scriptblock runs on a pool thread. The native readers only enqueue
# lines; the Windows Forms timer owns all parsing, console output and UI changes.
$nativeSource = @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace PhotoOrganizer {
    public static class Native {
        // box: App-owned terminal, never an editable source/destination field.
        // text: Already logged batch to append to the bounded on-screen buffer.
        // limit: Maximum visible characters; full text remains in disk logs.
        // retain: Tail to preserve when trimming old terminal content.
        // followTail: Scroll only this terminal, without moving its container.
        public static void AppendLogBatch(RichTextBox box, string text, int limit, int retain, bool followTail) {
            bool readOnly = box.ReadOnly;
            int selectionStart = box.SelectionStart;
            int selectionLength = box.SelectionLength;
            int removed = 0;
            if (text.Length > limit) { text = text.Substring(text.Length - limit); }
            SendLogMessage(box.Handle, 0x000B, IntPtr.Zero, IntPtr.Zero);
            try {
                // EM_REPLACESEL on a read-only RichEdit can beep and refuse
                // truncation. Unlock only during this synchronous UI batch.
                box.ReadOnly = false;
                if (box.TextLength + text.Length > limit) {
                    removed = Math.Min(box.TextLength, Math.Max(box.TextLength - retain,
                        box.TextLength + text.Length - limit));
                    box.Select(0, removed);
                    box.SelectedText = String.Empty;
                }
                box.AppendText(text);
                if (box.Focused) {
                    int start = Math.Max(0, selectionStart - removed);
                    box.Select(Math.Min(start, box.TextLength), Math.Min(selectionLength, Math.Max(0, box.TextLength - start)));
                }
                if (followTail && !box.Focused) { ScrollLogToBottom(box.Handle); }
            } finally {
                box.ReadOnly = readOnly;
                SendLogMessage(box.Handle, 0x000B, new IntPtr(1), IntPtr.Zero);
                box.Invalidate();
            }
        }

        // window: Existing log control; scroll its text, never the parent viewport.
        public static void ScrollLogToBottom(IntPtr window) {
            SendLogMessage(window, 0x0115, new IntPtr(7), IntPtr.Zero);
        }

        // window: Log window receiving a native scroll message.
        // message: WM_VSCROLL, confined to the log control.
        // value: SB_BOTTOM; no keyboard input or caret focus is simulated.
        // reserved: Always zero.
        [DllImport("user32.dll", EntryPoint = "SendMessageW")]
        private static extern IntPtr SendLogMessage(IntPtr window, int message, IntPtr value, IntPtr reserved);
        // path: App-owned font file, loaded privately for this process.
        // flags: FR_PRIVATE for portable, process-local font registration.
        // reserved: Must remain null.
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
        public static extern int AddFontResourceEx(string path, uint flags, IntPtr reserved);

        // window: Existing form handle, never a desktop/global theme target.
        // attribute: Windows immersive dark-title-bar attribute.
        // value: Whether dark title-bar rendering is requested.
        // size: Size of the integer attribute value.
        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);

        // context: The Windows DPI awareness context to enable.
        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr context);

        // context: The DPI context for this UI thread when the host already set one.
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

        // window: The top-level window whose actual monitor DPI is requested.
        [DllImport("user32.dll")]
        public static extern uint GetDpiForWindow(IntPtr window);

        // Exception: An unavailable Windows DPI API is reported to the caller.
        public static bool EnablePerMonitorDpi() {
            bool processEnabled = SetProcessDpiAwarenessContext(new IntPtr(-4));
            IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
            return processEnabled || previous != IntPtr.Zero;
        }

        // argument: One literal argument, including quotes and trailing backslashes.
        public static string QuoteArgument(string argument) {
            StringBuilder result = new StringBuilder("\"");
            int backslashes = 0;
            foreach (char character in argument) {
                if (character == '\\') { backslashes++; continue; }
                if (character == '"') {
                    result.Append('\\', backslashes * 2 + 1);
                    result.Append('"');
                } else {
                    result.Append('\\', backslashes);
                    result.Append(character);
                }
                backslashes = 0;
            }
            result.Append('\\', backslashes * 2);
            result.Append('"');
            return result.ToString();
        }
    }

    public sealed class DpiForm : Form {
        // Each window keeps its own minimum dimensions across monitor changes.
        public Size LogicalMinimumSize { get; set; }
        [StructLayout(LayoutKind.Sequential)]
        private struct WindowRectangle { public int Left, Top, Right, Bottom; }

        public DpiForm() {
            LogicalMinimumSize = new Size(740, 540);
            DoubleBuffered = true;
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
        }

        // message: A native window message, including monitor DPI changes.
        protected override void WndProc(ref Message message) {
            if (message.Msg != 0x02E0) { base.WndProc(ref message); return; }
            int dpi = (int)(message.WParam.ToInt64() & 0xffff);
            WindowRectangle suggested = (WindowRectangle)Marshal.PtrToStructure(
                message.LParam, typeof(WindowRectangle));
            SuspendLayout();
            try {
                base.WndProc(ref message);
                // PowerShell's host config does not opt into Framework DPI changes.
                // If Forms has already scaled, its dimensions prevent a second pass.
                if (dpi > 0 && Math.Abs(AutoScaleDimensions.Width - dpi) > 0.5F) {
                    float factor = dpi / AutoScaleDimensions.Width;
                    Scale(new SizeF(factor, factor));
                    AutoScaleDimensions = new SizeF(dpi, dpi);
                }
                MinimumSize = new Size((int)(LogicalMinimumSize.Width * dpi / 96F),
                    (int)(LogicalMinimumSize.Height * dpi / 96F));
                Bounds = Rectangle.FromLTRB(suggested.Left, suggested.Top,
                    suggested.Right, suggested.Bottom);
            } finally { ResumeLayout(true); }
            Invalidate(true);
        }
    }

    public class ThemeComboBox : ComboBox {
        public Color SelectionColor { get; set; }
        public Color DisabledTextColor { get; set; }

        public ThemeComboBox() {
            DrawMode = DrawMode.OwnerDrawFixed;
            FlatStyle = FlatStyle.Flat;
            SelectionColor = Color.FromArgb(23, 46, 73);
            DisabledTextColor = Color.Gray;
        }

        // eventArgs: Native list item or closed-selection painting request.
        protected override void OnDrawItem(DrawItemEventArgs eventArgs) {
            bool listSelection = (eventArgs.State & DrawItemState.Selected) != 0
                && (eventArgs.State & DrawItemState.ComboBoxEdit) == 0;
            Color background = listSelection ? SelectionColor : BackColor;
            Color foreground = !Enabled ? DisabledTextColor : (listSelection ? Color.White : ForeColor);
            using (Brush fill = new SolidBrush(background)) { eventArgs.Graphics.FillRectangle(fill, eventArgs.Bounds); }
            string caption = eventArgs.Index >= 0 && eventArgs.Index < Items.Count
                ? GetItemText(Items[eventArgs.Index]) : Text;
            Rectangle bounds = eventArgs.Bounds;
            bounds.Inflate(-6, 0);
            TextRenderer.DrawText(eventArgs.Graphics, caption, Font, bounds, foreground,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine
                | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
            if ((eventArgs.State & DrawItemState.Focus) != 0 && listSelection) { eventArgs.DrawFocusRectangle(); }
        }

        // eventArgs: Font change, including DPI/font preference updates.
        protected override void OnFontChanged(EventArgs eventArgs) {
            base.OnFontChanged(eventArgs);
            ItemHeight = Math.Max(18, Font.Height + 8);
        }

        // message: Paint the native arrow surface using the same theme as the field.
        protected override void WndProc(ref Message message) {
            base.WndProc(ref message);
            bool printing = message.Msg == 0x0317 || message.Msg == 0x0318;
            if ((message.Msg != 0x000F && !printing) || !IsHandleCreated || Width < 24) { return; }
            int buttonWidth = SystemInformation.VerticalScrollBarWidth;
            Rectangle button = new Rectangle(Width - buttonWidth - 1, 1, buttonWidth, Height - 2);
            using (Graphics graphics = printing && message.WParam != IntPtr.Zero
                ? Graphics.FromHdc(message.WParam) : Graphics.FromHwnd(Handle))
            using (Brush fill = new SolidBrush(BackColor))
            using (Pen border = new Pen(DisabledTextColor))
            using (Brush arrow = new SolidBrush(Enabled ? ForeColor : DisabledTextColor)) {
                graphics.FillRectangle(fill, button);
                int middleX = button.Left + button.Width / 2;
                int middleY = button.Top + button.Height / 2;
                graphics.FillPolygon(arrow, new Point[] { new Point(middleX - 4, middleY - 2),
                    new Point(middleX + 4, middleY - 2), new Point(middleX, middleY + 2) });
                graphics.DrawRectangle(border, 0, 0, Width - 1, Height - 1);
            }
        }
    }

    public sealed class PathComboBox : ThemeComboBox {
        [StructLayout(LayoutKind.Sequential)]
        private struct NativeRectangle { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)]
        private struct ComboInfo {
            public int Size;
            public NativeRectangle Item, Button;
            public int ButtonState;
            public IntPtr Combo, Edit, List;
        }
        // window: This combo's own native handle.
        // info: Receives the native edit child used by an editable ComboBox.
        [DllImport("user32.dll")]
        private static extern bool GetComboBoxInfo(IntPtr window, ref ComboInfo info);
        // window: The owned edit child.
        // message: EM_SETREADONLY for locking text without disabled black/gray rendering.
        // value: Nonzero to prohibit editing.
        // reserved: Unused message argument.
        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr window, int message, IntPtr value, IntPtr reserved);
        private bool locked;
        public bool IsReadOnly {
            get { return locked; }
            set {
                locked = value;
                if (locked) { DroppedDown = false; }
                AutoCompleteMode = locked ? AutoCompleteMode.None : AutoCompleteMode.SuggestAppend;
                ApplyReadOnly();
            }
        }
        private void ApplyReadOnly() {
            if (!IsHandleCreated) { return; }
            ComboInfo info = new ComboInfo();
            info.Size = Marshal.SizeOf(typeof(ComboInfo));
            if (GetComboBoxInfo(Handle, ref info) && info.Edit != IntPtr.Zero) {
                SendMessage(info.Edit, 0x00B1, new IntPtr(locked ? 1 : 0), IntPtr.Zero);
            }
        }
        // e: Reapply the lock if Windows recreates the native combo/edit handles.
        protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); ApplyReadOnly(); }
        // message: Prevent list navigation while retaining selectable, readable text.
        protected override void WndProc(ref Message message) {
            if (locked && (message.Msg == 0x0201 || message.Msg == 0x020A || (message.Msg == 0x014F && message.WParam != IntPtr.Zero) ||
                (message.Msg == 0x0100 && (message.WParam.ToInt32() == 0x73 || message.WParam.ToInt32() == 0x26 || message.WParam.ToInt32() == 0x28)))) {
                return;
            }
            base.WndProc(ref message);
        }
    }

    public sealed class ThemeButton : Button {
        public Color DisabledTextColor { get; set; }
        public ThemeButton() {
            DisabledTextColor = SystemColors.GrayText;
            DoubleBuffered = true;
        }

        // e: Paint only the disabled state; native enabled mouse/keyboard behavior stays intact.
        protected override void OnPaint(PaintEventArgs e) {
            if (Enabled) { base.OnPaint(e); return; }
            e.Graphics.Clear(BackColor);
            if (FlatAppearance.BorderSize > 0) {
                using (Pen border = new Pen(FlatAppearance.BorderColor, FlatAppearance.BorderSize)) {
                    e.Graphics.DrawRectangle(border, 0, 0, Math.Max(0, Width - 1), Math.Max(0, Height - 1));
                }
            }
            Rectangle textBounds = Rectangle.Inflate(ClientRectangle, -Padding.Left, -Padding.Top);
            TextRenderer.DrawText(e.Graphics, Text, Font, textBounds, DisabledTextColor,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.HidePrefix);
        }
    }

    public sealed class ThemeCheckBox : CheckBox {
        public Color DisabledTextColor { get; set; }
        public ThemeCheckBox() {
            DisabledTextColor = SystemColors.GrayText;
            DoubleBuffered = true;
        }

        // e: Keep disabled captions readable without making the checkbox interactive.
        protected override void OnPaint(PaintEventArgs e) {
            if (Enabled) { base.OnPaint(e); return; }
            e.Graphics.Clear(BackColor);
            System.Windows.Forms.VisualStyles.CheckBoxState state = Checked
                ? System.Windows.Forms.VisualStyles.CheckBoxState.CheckedDisabled
                : System.Windows.Forms.VisualStyles.CheckBoxState.UncheckedDisabled;
            Size glyph = CheckBoxRenderer.GetGlyphSize(e.Graphics, state);
            int gap = Math.Max(4, (int)(6 * e.Graphics.DpiX / 96F));
            CheckBoxRenderer.DrawCheckBox(e.Graphics, new Point(Padding.Left,
                Math.Max(Padding.Top, (Height - glyph.Height) / 2)), state);
            Rectangle textBounds = new Rectangle(Padding.Left + glyph.Width + gap, Padding.Top,
                Math.Max(0, Width - Padding.Horizontal - glyph.Width - gap), Math.Max(0, Height - Padding.Vertical));
            TextRenderer.DrawText(e.Graphics, Text, Font, textBounds, DisabledTextColor,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak | TextFormatFlags.HidePrefix);
        }
    }

    public class BufferedPanel : Panel {
        public BufferedPanel() {
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }
    }

    public sealed class StableScrollPanel : BufferedPanel {
        public bool SuppressFocusScroll { get; set; }

        // control: Child requesting visibility while background output changes.
        protected override Point ScrollToControl(Control control) {
            return SuppressFocusScroll ? DisplayRectangle.Location : base.ScrollToControl(control);
        }

        // eventArgs: Explicit viewport scroll; repaint translated child surfaces.
        protected override void OnScroll(ScrollEventArgs eventArgs) {
            base.OnScroll(eventArgs);
            if (eventArgs.NewValue != eventArgs.OldValue) { Invalidate(true); }
        }
    }

    public sealed class ThemeTabControl : TabControl {
        public Color CanvasColor { get; set; }
        public Color SurfaceColor { get; set; }
        public Color BorderColor { get; set; }
        public Color MutedColor { get; set; }
        public Color AccentColor { get; set; }
        public ThemeTabControl() {
            CanvasColor = SystemColors.Control;
            SurfaceColor = SystemColors.Window;
            BorderColor = SystemColors.ControlDark;
            MutedColor = SystemColors.GrayText;
            AccentColor = Color.Teal;
            Alignment = TabAlignment.Top;
            SizeMode = TabSizeMode.Fixed;
            Padding = new Point(12, 7);
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint |
                ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        }

        // Size all native tab rectangles for the actual monospace drawing font.
        private void UpdateHeaderSize() {
            int width = 64;
            foreach (TabPage page in TabPages) {
                width = Math.Max(width, TextRenderer.MeasureText(page.Text, Font, Size.Empty,
                    TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.NoPadding).Width + Padding.X * 2);
            }
            ItemSize = new Size(width, Math.Max(28, Font.Height + Padding.Y * 2 + 6));
        }

        // eventArgs: Updated font, including portable font preference changes.
        protected override void OnFontChanged(EventArgs eventArgs) {
            base.OnFontChanged(eventArgs); UpdateHeaderSize();
        }

        // eventArgs: New settings page whose caption may need a wider header.
        protected override void OnControlAdded(ControlEventArgs eventArgs) {
            base.OnControlAdded(eventArgs); UpdateHeaderSize();
        }

        // e: Paint the entire tab chrome, including the native light surround.
        protected override void OnPaintBackground(PaintEventArgs e) { e.Graphics.Clear(CanvasColor); }

        // e: Custom headers keep native tab selection, keyboard navigation and page layout.
        protected override void OnPaint(PaintEventArgs e) {
            Rectangle page = DisplayRectangle;
            page.Inflate(1, 1);
            using (SolidBrush surface = new SolidBrush(SurfaceColor)) { e.Graphics.FillRectangle(surface, page); }
            using (Pen border = new Pen(BorderColor)) { e.Graphics.DrawRectangle(border, page); }
            for (int index = 0; index < TabCount; index++) {
                Rectangle bounds = GetTabRect(index);
                bool selected = index == SelectedIndex;
                using (SolidBrush fill = new SolidBrush(selected ? SurfaceColor : CanvasColor)) {
                    e.Graphics.FillRectangle(fill, bounds);
                }
                Color textColor = Enabled ? (selected ? ForeColor : MutedColor) : MutedColor;
                TextRenderer.DrawText(e.Graphics, TabPages[index].Text, Font, bounds, textColor,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter |
                    TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
                if (selected) {
                    int height = Math.Max(2, (int)(3 * e.Graphics.DpiY / 96F));
                    using (SolidBrush accent = new SolidBrush(AccentColor)) {
                        e.Graphics.FillRectangle(accent, bounds.Left, bounds.Bottom - height, bounds.Width, height);
                    }
                    if (Focused && ShowFocusCues) { ControlPaint.DrawFocusRectangle(e.Graphics, Rectangle.Inflate(bounds, -4, -4), textColor, SurfaceColor); }
                }
            }
            base.OnPaint(e);
        }

        // e: Repaint headers only when selection changes, not on every setup log update.
        protected override void OnSelectedIndexChanged(EventArgs e) { base.OnSelectedIndexChanged(e); Invalidate(); }
    }

    public sealed class BufferedTable : TableLayoutPanel {
        public BufferedTable() {
            DoubleBuffered = true;
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer, true);
        }
    }

    public sealed class CardPanel : BufferedPanel {
        public Color FillColor { get; set; }
        public Color BorderColor { get; set; }
        public CardPanel() {
            FillColor = Color.White;
            BorderColor = Color.FromArgb(221, 229, 239);
            DoubleBuffered = true;
            SetStyle(ControlStyles.ResizeRedraw, true);
            BackColor = Color.FromArgb(242, 246, 250);
        }

        // e: Graphics and clipping information for the card surface.
        protected override void OnPaint(PaintEventArgs e) {
            base.OnPaint(e);
            float radius = 12F * e.Graphics.DpiX / 96F;
            float diameter = radius * 2F;
            RectangleF rectangle = new RectangleF(0.5F, 0.5F, Width - 1F, Height - 1F);
            if (rectangle.Width < diameter || rectangle.Height < diameter) { return; }
            using (GraphicsPath path = new GraphicsPath()) {
                path.AddArc(rectangle.Left, rectangle.Top, diameter, diameter, 180, 90);
                path.AddArc(rectangle.Right - diameter, rectangle.Top, diameter, diameter, 270, 90);
                path.AddArc(rectangle.Right - diameter, rectangle.Bottom - diameter, diameter, diameter, 0, 90);
                path.AddArc(rectangle.Left, rectangle.Bottom - diameter, diameter, diameter, 90, 90);
                path.CloseFigure();
                e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
                using (Brush fill = new SolidBrush(FillColor)) { e.Graphics.FillPath(fill, path); }
                using (Pen border = new Pen(BorderColor)) { e.Graphics.DrawPath(border, path); }
            }
        }
    }

    public sealed class OutputLine {
        public string Kind;
        public string Text;
        // kind: stdout, stderr, fault, or exit.
        // text: The unmodified line or exit code.
        public OutputLine(string kind, string text) { Kind = kind; Text = text; }
    }

    public sealed class ProcessWorker : IDisposable {
        private readonly ConcurrentQueue<OutputLine> queue = new ConcurrentQueue<OutputLine>();
        private readonly SemaphoreSlim available = new SemaphoreSlim(4096, 4096);
        private readonly CancellationTokenSource cancellation = new CancellationTokenSource();
        private Process process;
        private Task completion;
        public bool IsCompleted { get { return completion != null && completion.IsCompleted; } }
        public int ProcessId { get { return process.Id; } }

        // kind: The stream or lifecycle event name.
        // text: Text to pass to the UI without executing it.
        private void Enqueue(string kind, string text) {
            try {
                available.Wait(cancellation.Token);
                queue.Enqueue(new OutputLine(kind, text));
            } catch (OperationCanceledException) { }
        }

        // reader: One redirected stream, owned by the process.
        // kind: The stream name included with each line.
        private void ReadStream(StreamReader reader, string kind) {
            try {
                string line;
                while ((line = reader.ReadLine()) != null) { Enqueue(kind, line); }
            } catch (Exception error) { Enqueue("fault", error.Message); }
        }

        // info: Child-only environment and the fully quoted Python command.
        // Exception: A start failure is propagated; no worker is left running.
        public void Start(ProcessStartInfo info) {
            if (process != null) { throw new InvalidOperationException("Worker gia avviato."); }
            process = new Process();
            process.StartInfo = info;
            try {
                if (!process.Start()) { throw new InvalidOperationException("Avvio del backend non riuscito."); }
            } catch { process.Dispose(); process = null; throw; }
            // LongRunning gives each stream its own reader. Neither can deadlock
            // the other when stderr fills; queue backpressure stays off the UI.
            Task stdout = Task.Factory.StartNew(() => ReadStream(process.StandardOutput, "stdout"),
                CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
            Task stderr = Task.Factory.StartNew(() => ReadStream(process.StandardError, "stderr"),
                CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
            completion = Task.Factory.StartNew(() => {
                try {
                    process.WaitForExit();
                    Task.WaitAll(stdout, stderr);
                    Enqueue("exit", process.ExitCode.ToString());
                } catch (Exception error) {
                    Enqueue("fault", error.Message);
                    Enqueue("exit", "-1");
                }
            }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        }

        // line: The next queued output line, or null when the queue is empty.
        public bool TryTake(out OutputLine line) {
            if (!queue.TryDequeue(out line)) { return false; }
            available.Release();
            return true;
        }

        // Exception: A failure to stop the explicitly confirmed process is propagated.
        public void StopAfterConfirmation() {
            if (process != null && !process.HasExited) { process.Kill(); }
        }

        public void Dispose() {
            // Never terminate a child during cleanup. The UI waits for completion.
            cancellation.Cancel();
            if (completion == null || completion.IsCompleted) {
                if (process != null) { process.Dispose(); }
                cancellation.Dispose();
                available.Dispose();
            }
        }
    }
}
'@
if (-not ('PhotoOrganizer.Native' -as [type])) {
    Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Core
}

# Must run before any form, dialog, control handle or visual-style initialization.
$dpiEnabled = [PhotoOrganizer.Native]::EnablePerMonitorDpi()
[Windows.Forms.Application]::EnableVisualStyles()
[Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:palette = @{
    Navy = [Drawing.ColorTranslator]::FromHtml('#10253F')
    Cyan = [Drawing.ColorTranslator]::FromHtml('#00C2D7')
    Ink = [Drawing.ColorTranslator]::FromHtml('#172E49')
    Muted = [Drawing.ColorTranslator]::FromHtml('#60738A')
    Canvas = [Drawing.ColorTranslator]::FromHtml('#F2F6FA')
    Green = [Drawing.ColorTranslator]::FromHtml('#147D61')
    Amber = [Drawing.ColorTranslator]::FromHtml('#9B6414')
    Red = [Drawing.ColorTranslator]::FromHtml('#B23C45')
}
$script:state = @{
    Worker = $null; Mode = ''; ActiveDestination = ''; PauseRequested = $false
    ClosePending = $false; ForceStopped = $false; TimerBusy = $false
    DestinationCustomized = $false; SettingDestination = $false
    LastSummary = $null; HadError = $false; ExitSeen = $false; ExitCode = 0
    LastConsoleProgress = [datetime]::MinValue; SmokeError = $null
    WorkflowStep = 0; WorkflowRoot = ''; WorkflowResults = @(); OriginalHashes = @{}
    FirstOutputHashes = @{}; WorkflowStarted = $false
    CleanupPlan = $null
    PendingProgress = $null
    SourceRelocation = $null
    SidecarRecovery = $null
    LogBuffer = (New-Object Text.StringBuilder)
    LastLogFlush = [datetime]::MinValue
}
$script:smokeMode = [bool]($UiSmokeTest -or $DialogSmokeTest)
$script:dialogSmokeMode = [bool]$DialogSmokeTest
$script:workflowTestMode = [bool]$WorkflowSmokeTest
. (Join-Path $script:appRoot 'scripts\Ui-Options.ps1')
. (Join-Path $script:appRoot 'scripts\Ui-Paths.ps1')
. (Join-Path $script:appRoot 'scripts\Ui-Cleanup.ps1')
. (Join-Path $script:appRoot 'scripts\Ui-Branding.ps1')
. (Join-Path $script:appRoot 'scripts\Ui-Smoke.ps1')
Initialize-UiPreferences
Initialize-PathHistory
Initialize-AppBranding
$guiLogFolder = Join-Path $script:appRoot 'logs\photo-organizer'
[void][IO.Directory]::CreateDirectory($guiLogFolder)
$script:guiLogPath = Join-Path $guiLogFolder ('gui-' + [datetime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N') + '.jsonl')

# Text: Visible label text, with no accelerator interpretation.
# Size: Font size in points.
# Bold: Use the Semibold visual weight.
# Color: Optional foreground color.
function New-UiLabel {
    param([string]$Text, [single]$Size = 10, [switch]$Bold, [Drawing.Color]$Color = $script:palette.Ink)
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.AutoSize = $true
    $label.Dock = 'Fill'
    $label.UseMnemonic = $false
    $label.BackColor = [Drawing.Color]::Transparent
    $label.ForeColor = $Color
    $label.Tag = if ($Color -eq $script:palette.Muted) { 'muted' } elseif ($Color -eq $script:palette.Green) { 'green' } elseif ($Color -eq $script:palette.Amber) { 'amber' } elseif ($Color -eq $script:palette.Red) { 'red' } elseif ($Color -eq $script:palette.Ink) { 'ink' } else { 'fixed' }
    $label.Font = New-AppFont $Size $(if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular })
    $label.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 6)
    return $label
}

# Columns: Number of equal-width columns in the adaptive table.
function New-UiTable {
    param([int]$Columns = 1)
    $table = New-Object PhotoOrganizer.BufferedTable
    $table.ColumnCount = $Columns
    $table.RowCount = 0
    $table.AutoSize = $true
    $table.AutoSizeMode = 'GrowAndShrink'
    $table.Dock = 'Top'
    $table.BackColor = [Drawing.Color]::Transparent
    $table.Margin = New-Object Windows.Forms.Padding(0)
    $table.GrowStyle = 'AddRows'
    for ($column = 0; $column -lt $Columns; $column++) {
        [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', (100 / $Columns))))
    }
    return $table
}

# Table: A table with one or more columns.
# Control: The control to append in a new, automatically sized row.
# Span: Number of columns covered by this control.
function Add-UiRow {
    param([Windows.Forms.TableLayoutPanel]$Table, [Windows.Forms.Control]$Control, [int]$Span = 1)
    $row = $Table.RowCount
    $Table.RowCount++
    [void]$Table.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    $Table.Controls.Add($Control, 0, $row)
    if ($Span -gt 1) { $Table.SetColumnSpan($Control, $Span) }
}

# Title: Number and title displayed at the top of the card.
function New-UiCard {
    param([string]$Title)
    $card = New-Object PhotoOrganizer.CardPanel
    $card.AutoSize = $true
    $card.AutoSizeMode = 'GrowAndShrink'
    $card.Dock = 'Top'
    $card.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 14)
    $card.Padding = New-Object Windows.Forms.Padding(20, 16, 20, 14)
    $content = New-UiTable
    $card.Controls.Add($content)
    $heading = New-UiLabel $Title -Size 12 -Bold
    $heading.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 12)
    Add-UiRow $content $heading
    return @{ Panel = $card; Content = $content }
}

# Text: Button caption, including its keyboard accelerator.
# Primary: Use the cyan primary action appearance.
function New-UiButton {
    param([string]$Text, [switch]$Primary)
    $button = New-Object PhotoOrganizer.ThemeButton
    $button.Text = $Text
    $button.AutoSize = $true
    $button.AutoSizeMode = 'GrowAndShrink'
    $button.MinimumSize = New-Object Drawing.Size(116, 38)
    $button.Padding = New-Object Windows.Forms.Padding(14, 5, 14, 5)
    $button.Margin = New-Object Windows.Forms.Padding(0, 0, 10, 8)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 1
    $button.FlatAppearance.BorderColor = [Drawing.ColorTranslator]::FromHtml('#CFDBE8')
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    $button.Font = New-AppFont 10 ([Drawing.FontStyle]::Bold)
    $button.Tag = if ($Primary) { 'primary' } else { 'button' }
    $button.BackColor = [Drawing.Color]::White
    $button.ForeColor = $script:palette.Ink
    if ($Primary) {
        $button.BackColor = $script:palette.Cyan
        $button.FlatAppearance.BorderSize = 0
        $button.FlatAppearance.MouseOverBackColor = [Drawing.ColorTranslator]::FromHtml('#3DD5E3')
        $button.FlatAppearance.MouseDownBackColor = [Drawing.ColorTranslator]::FromHtml('#00A5BA')
    }
    return $button
}

# Text: One line to display in the bounded log and the launching console.
# Level: Human-readable event category.
function Write-UiLog {
    param([string]$Text, [string]$Level = 'INFO')
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    $line = '[{0:HH:mm:ss}] {1,-8} {2}' -f [datetime]::Now, $Level, $Text
    Write-AppSessionLog 'ui' $line
    [void]$script:state.LogBuffer.AppendLine($line)
    Write-Host $line
}

# Force: Flush immediately for a final state; normal updates are limited to four per second.
function Flush-UiLog {
    param([switch]$Force)
    if ($script:state.LogBuffer.Length -eq 0 -or $null -eq $script:logBox -or $script:logBox.IsDisposed) { return }
    if (-not $Force -and ([datetime]::UtcNow - $script:state.LastLogFlush).TotalMilliseconds -lt 250) { return }
    $text = $script:state.LogBuffer.ToString()
    [void]$script:state.LogBuffer.Clear()
    $previousSuppression = $script:workspace.SuppressFocusScroll
    $script:workspace.SuppressFocusScroll = $true
    try {
        # Scroll only the inner native text viewport. ScrollToCaret used to
        # pull the card stack up, then restoring AutoScrollPosition pulled it
        # down again and left translated/doubled child pixels behind.
        [PhotoOrganizer.Native]::AppendLogBatch($script:logBox, $text, 100000, 75000, $true)
    } finally { $script:workspace.SuppressFocusScroll = $previousSuppression }
    $script:state.LastLogFlush = [datetime]::UtcNow
}

# Text: Current status or outcome.
# Tone: Palette key for the status foreground.
function Set-UiStatus {
    param([string]$Text, [string]$Tone = 'Muted')
    $script:statusLabel.Text = $Text
    $script:statusLabel.ForeColor = $script:palette[$Tone]
}

# ErrorRecord: The caught exception or a user-facing message.
function Show-UiError {
    param($ErrorRecord)
    $message = if ($ErrorRecord -is [Management.Automation.ErrorRecord]) {
        $ErrorRecord.Exception.Message
    } else { [string]$ErrorRecord }
    Write-UiLog $message 'ERRORE'
    Set-UiStatus $message 'Red'
    [void][Windows.Forms.MessageBox]::Show($script:form, $message, 'Photo Organizer', 'OK', 'Error')
}

# Path: User-entered absolute directory path; no enumeration or source-content reads.
# Exception: Invalid, relative, or device paths are refused.
function Resolve-DirectoryText {
    param([string]$Path)
    $text = $Path.Trim()
    if ($text.Length -ge 2 -and $text[0] -eq '"' -and $text[$text.Length - 1] -eq '"') {
        $text = $text.Substring(1, $text.Length - 2)
    }
    if ($text -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)' -or $text -match '^\\\\[?.]\\') {
        throw 'Indica un percorso assoluto, per esempio E:\Foto oppure \\server\condivisione\Foto.'
    }
    $fullPath = [IO.Path]::GetFullPath($text)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Length -gt $root.Length) { $fullPath = $fullPath.TrimEnd([char[]]'\/') }
    return $fullPath
}

# First: First normalized absolute directory path.
# Second: Second normalized absolute directory path.
function Test-DirectoryOverlap {
    param([string]$First, [string]$Second)
    $left = $First.TrimEnd([char[]]'\/') + '\'
    $right = $Second.TrimEnd([char[]]'\/') + '\'
    return $left.StartsWith($right, [StringComparison]::OrdinalIgnoreCase) -or
        $right.StartsWith($left, [StringComparison]::OrdinalIgnoreCase)
}

function Update-DefaultDestination {
    if ($script:state.SettingDestination) { return }
    if ($script:state.DestinationCustomized) { return }
    $source = $script:sourceBox.Text.Trim().Trim('"').TrimEnd([char[]]'\/')
    $name = 'cartella'
    if (-not [string]::IsNullOrWhiteSpace($source)) {
        try {
            $candidate = [IO.Path]::GetFileName($source)
            $candidate = $candidate -replace '[<>:"/\\|?*]', '-'
            if (-not [string]::IsNullOrWhiteSpace($candidate)) { $name = $candidate }
        } catch { return }
    }
    $script:state.SettingDestination = $true
    try { $script:destinationBox.Text = Join-Path $PSScriptRoot ('output\preview-' + $name) }
    finally { $script:state.SettingDestination = $false }
}

# Target: Text box receiving the selected directory.
# Description: Italian dialog purpose.
function Select-Directory {
    param([Windows.Forms.Control]$Target, [string]$Description)
    if ($script:smokeMode) { return }
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description = $Description
        $dialog.ShowNewFolderButton = ($Target -eq $script:destinationBox)
        if ([IO.Directory]::Exists($Target.Text)) { $dialog.SelectedPath = $Target.Text }
        if ($dialog.ShowDialog($script:form) -eq 'OK') {
            $Target.Text = $dialog.SelectedPath
            if ($Target -eq $script:sourceBox -or $Target -eq $script:destinationBox) {
                try { Remember-PathSelection $script:sourceBox.Text $script:destinationBox.Text }
                catch { Write-UiLog ('Percorso selezionato; cronologia non salvata: ' + $_.Exception.Message) 'ERRORE' }
            }
        }
    } finally { $dialog.Dispose() }
}

# Busy: Whether a workflow currently owns the process slot.
function Set-UiBusy {
    param([bool]$Busy)
    foreach ($control in @($script:sourceBox, $script:destinationBox, $script:sourceBrowse,
        $script:destinationBrowse, $script:aiOption, $script:transcribeOption, $script:videoDescriptionOption,
        $script:simulateButton, $script:copyButton, $script:verifyButton, $script:optionsButton) + $script:cleanupControls) {
        if ($control -is [PhotoOrganizer.PathComboBox]) {
            $control.IsReadOnly = $Busy
            $control.Enabled = $true
        } elseif ($control -is [Windows.Forms.TextBox]) {
            # Read-only locks the input while keeping native text selectable and legible.
            $control.ReadOnly = $Busy
            $control.Enabled = $true
        } else { $control.Enabled = -not $Busy }
    }
    $script:pauseButton.Enabled = $Busy -and $script:state.Mode -ne 'what-if' -and -not $script:state.PauseRequested
    $script:openButton.Enabled = $true
    $script:cleanupApply.Enabled = -not $Busy -and $null -ne $script:state.CleanupPlan
    $script:sessionLabel.Text = if ($Busy) { 'IN CORSO' } else { 'PRONTO' }
}

# Mode: Explicit backend mode, even though what-if is its default.
# RecoveryHash: user-approved inventory digest for damaged sidecars, never an automatic opt-in.
# Exception: Invalid inputs, missing runtime/backend, or a launch failure are surfaced.
function Start-OrganizerWorkflow {
    param([ValidateSet('what-if', 'run', 'verify-only', 'relocate-source', 'cleanup-index', 'cleanup-plan', 'cleanup-apply')][string]$Mode = 'what-if',
          [string]$RecoveryHash = '')
    if ($script:smokeMode) { return }
    if ($null -ne $script:state.Worker) { throw 'Attendi la conclusione del processo corrente.' }
    $cleanup = $Mode.StartsWith('cleanup-')
    $source = Resolve-DirectoryText $(if ($cleanup) { $script:cleanupSource.Text } else { $script:sourceBox.Text })
    $destination = Resolve-DirectoryText $(if ($cleanup) { $script:cleanupTarget.Text } else { $script:destinationBox.Text })
    if ($cleanup -and -not [IO.Directory]::Exists($destination)) { throw 'Seleziona il target esistente che contiene le copie conservate.' }
    if ($Mode -eq 'cleanup-apply' -and -not (Confirm-CleanupPlan $source $destination)) { return }
    if (Test-DirectoryOverlap $source $destination) {
        throw 'Origine e destinazione devono essere separate: non possono coincidere o contenersi.'
    }
    if (-not [IO.Directory]::Exists($source)) { throw 'La cartella di origine non esiste o non è accessibile.' }
    if ([IO.File]::Exists($destination)) { throw 'La destinazione indica un file, non una cartella.' }
    if (-not $cleanup) {
        try { Remember-PathSelection $script:sourceBox.Text $script:destinationBox.Text }
        catch { Write-UiLog ('Cronologia non salvata; il lavoro puo continuare: ' + $_.Exception.Message) 'ERRORE' }
    }
    if ($Mode -eq 'verify-only' -and -not [IO.Directory]::Exists($destination)) {
        throw 'La cartella di output non esiste ancora. Esegui prima una copia.'
    }
    $python = Join-Path $PSScriptRoot 'runtime\python\python.exe'
    $backend = Join-Path $PSScriptRoot $(if ($cleanup) { 'scripts\cleanup_processed.py' } else { 'scripts\folder_organizer.py' })
    if (-not [IO.File]::Exists($python)) { throw ('Python portabile non trovato: ' + $python) }
    if (-not [IO.File]::Exists($backend)) { throw ('Backend di copia non trovato: ' + $backend) }

    if ($cleanup) {
        $flag = switch ($Mode) { 'cleanup-index' { '--index' } 'cleanup-apply' { '--apply' } default { '--what-if' } }
        $arguments = @('-B', '-u', $backend, '--source', $source, '--target', $destination, $flag, '--limit', [string]$script:cleanupLimit.Value)
        if ($Mode -eq 'cleanup-apply') {
            $arguments += @('--plan-id', $script:state.CleanupPlan.plan_id, '--confirm-plan-hash', $script:state.CleanupPlan.confirmation_hash)
        } else { $script:state.CleanupPlan = $null; $script:cleanupGrid.Rows.Clear() }
    } else { $arguments = @('-B', '-u', $backend, '--source', $source, '--destination', $destination, ('--' + $Mode)) }
    if ($Mode -in @('run', 'relocate-source')) { $arguments += '--allow-cloud' }
    if ($Mode -eq 'run' -and $script:transcribeOption.Checked) { $arguments += '--transcribe' }
    if ($Mode -eq 'run' -and $script:videoDescriptionOption.Checked) { $arguments += '--describe-videos' }
    if ($RecoveryHash) {
        if ($Mode -ne 'relocate-source') { throw 'Conferma recupero disponibile solo nella verifica sorgente.' }
        $arguments += @('--confirm-sidecar-recovery', $RecoveryHash)
    }
    if (-not $cleanup -and -not $script:aiOption.Checked) { $arguments += '--no-ai' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $python
    $info.Arguments = ($arguments | ForEach-Object { [PhotoOrganizer.Native]::QuoteArgument($_) }) -join ' '
    $info.WorkingDirectory = $PSScriptRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $childTemp = Join-Path $PSScriptRoot 'temp\photo-organizer'
    [void][IO.Directory]::CreateDirectory($childTemp)
    $info.EnvironmentVariables['TEMP'] = $childTemp
    $info.EnvironmentVariables['TMP'] = $childTemp
    $info.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $info.EnvironmentVariables['PYTHONUTF8'] = '1'
    $info.EnvironmentVariables['PYTHONDONTWRITEBYTECODE'] = '1'

    $worker = New-Object PhotoOrganizer.ProcessWorker
    try { $worker.Start($info) } catch { $worker.Dispose(); throw }
    $script:state.Worker = $worker
    $script:state.Mode = $Mode
    $script:state.ActiveDestination = $destination
    $script:state.PauseRequested = $false
    $script:state.ClosePending = $false
    $script:state.ForceStopped = $false
    $script:state.LastSummary = $null
    $script:state.SourceRelocation = $null
    $script:state.SidecarRecovery = $null
    $script:state.HadError = $false
    $script:state.ExitSeen = $false
    $script:state.LastConsoleProgress = [datetime]::MinValue
    $script:progressBar.Style = 'Marquee'
    $script:progressBar.Value = 0
    $script:countValue.Text = '0 / --'
    $script:bytesValue.Text = '--'
    $script:rateValue.Text = '--'
    $script:etaValue.Text = '--'
    $script:elapsedLabel.Text = 'Tempo trascorso: --'
    $script:summaryLabel.Text = 'In attesa del riepilogo del backend.'
    $script:fileLabel.Text = 'Avvio del processo...'
    $caption = switch ($Mode) { 'run' { 'Copia / ripresa' } 'verify-only' { 'Verifica output' } 'relocate-source' { 'Verifica sorgente trasferita' } 'cleanup-index' { 'Indice target' } 'cleanup-plan' { 'Simula pulizia' } 'cleanup-apply' { 'Cestino: copie verificate' } default { 'Simulazione' } }
    $script:phaseLabel.Text = $caption
    Set-UiStatus ($caption + ' in corso...')
    Set-UiBusy $true
    Write-UiLog ('{0} | PID {1} | {2} -> {3}' -f $caption, $worker.ProcessId, $source, $destination)
}

# Exception: A pause marker cannot be created, for example if output is inaccessible.
function Request-OrganizerPause {
    if ($null -eq $script:state.Worker -or $script:state.PauseRequested) { return }
    if ($script:state.Mode -eq 'what-if') {
        # A simulation must never create the destination just to request a pause.
        $script:state.PauseRequested = $true
        Write-UiLog 'Attendo la fine della scansione senza creare file o cartelle di output.' 'ATTESA'
        return
    }
    $controlName = if ($script:state.Mode.StartsWith('cleanup-')) { '.photo-cleanup' } else { '.photo-organizer' }
    $controlDirectory = Join-Path $script:state.ActiveDestination $controlName
    [void][IO.Directory]::CreateDirectory($controlDirectory)
    $request = Join-Path $controlDirectory 'pause.request'
    [IO.File]::WriteAllText($request, 'pause', (New-Object Text.UTF8Encoding($false)))
    $script:state.PauseRequested = $true
    $script:pauseButton.Enabled = $false
    $script:pauseButton.Text = 'Pausa richiesta'
    Set-UiStatus 'Pausa richiesta: attendo il punto sicuro del backend.' 'Amber'
    Write-UiLog 'Pausa cooperativa richiesta. Il backend rimuoverà la richiesta alla prossima esecuzione.' 'PAUSA'
}

# Object: Parsed JSON object, possibly missing optional fields.
# Name: Property to read without StrictMode errors.
# Default: Value returned for absent or null fields.
function Get-EventValue {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

# Value: Optional numeric field; only finite non-negative values are accepted.
function Get-NonnegativeNumber {
    param($Value)
    $number = 0.0
    if ($null -eq $Value -or -not [double]::TryParse([string]$Value,
        [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) { return $null }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0) { return $null }
    return $number
}

# Bytes: Byte count, never read from the filesystem.
function Format-ByteCount {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GiB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MiB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KiB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

# Seconds: Backend elapsed or remaining seconds.
function Format-Duration {
    param([double]$Seconds)
    $secondsValue = [Math]::Min($Seconds, 315360000)
    $duration = [TimeSpan]::FromSeconds($secondsValue)
    if ($duration.TotalHours -ge 1) { return ('{0:N0} h {1:00} min' -f [Math]::Floor($duration.TotalHours), $duration.Minutes) }
    return ('{0:00}:{1:00}' -f [Math]::Floor($duration.TotalMinutes), $duration.Seconds)
}

# Payload: Optional backend scan or progress properties.
function Update-OrganizerProgress {
    param($Payload)
    $phase = [string](Get-EventValue $Payload 'phase' '')
    if ($phase) {
        $phaseText = switch -Regex ($phase) {
            '^(scan|scanning)$' { 'Scansione'; break }
            '^(copy|copying)$' { 'Copia'; break }
            '^(ai|analysis|analyzing)$' { 'Analisi AI'; break }
            '^(verify|verification|verifying)$' { 'Verifica'; break }
            '^(plan|planning|what-if)$' { 'Simulazione'; break }
            default { $phase }
        }
        $script:phaseLabel.Text = $phaseText
    }
    $filename = [string](Get-EventValue $Payload 'filename' '')
    if ($filename) { $script:fileLabel.Text = $filename; $script:toolTip.SetToolTip($script:fileLabel, $filename) }
    $done = Get-NonnegativeNumber (Get-EventValue $Payload 'done')
    $total = Get-NonnegativeNumber (Get-EventValue $Payload 'total')
    if ($null -ne $done) {
        $totalText = if ($null -ne $total) { '{0:N0}' -f $total } else { '--' }
        $script:countValue.Text = '{0:N0} / {1}' -f $done, $totalText
    }
    if ($null -ne $done -and $null -ne $total -and $total -gt 0) {
        $script:progressBar.Style = 'Continuous'
        $script:progressBar.Value = [int][Math]::Min(1000, [Math]::Max(0, 1000 * $done / $total))
    } else { $script:progressBar.Style = 'Marquee' }
    $bytesDone = Get-NonnegativeNumber (Get-EventValue $Payload 'bytes_done')
    $bytesTotal = Get-NonnegativeNumber (Get-EventValue $Payload 'bytes_total')
    if ($null -ne $bytesDone) {
        $script:bytesValue.Text = Format-ByteCount $bytesDone
        if ($null -ne $bytesTotal) { $script:bytesValue.Text += ' / ' + (Format-ByteCount $bytesTotal) }
    }
    $rate = Get-NonnegativeNumber (Get-EventValue $Payload 'rate_mib_s')
    if ($null -ne $rate) { $script:rateValue.Text = '{0:N1} MiB/s' -f $rate }
    $eta = Get-NonnegativeNumber (Get-EventValue $Payload 'eta_seconds')
    $elapsed = Get-NonnegativeNumber (Get-EventValue $Payload 'elapsed_seconds')
    $script:etaValue.Text = if ($null -ne $eta) { Format-Duration $eta } else { '--' }
    if ($null -ne $elapsed) { $script:elapsedLabel.Text = 'Tempo trascorso: ' + (Format-Duration $elapsed) }
    # Console progress is throttled; the GUI still receives every queued event.
    if (([datetime]::Now - $script:state.LastConsoleProgress).TotalSeconds -ge 1) {
        Write-Host ('[{0:HH:mm:ss}] {1} | file {2} | {3} | {4} | ETA {5} | {6}' -f
            [datetime]::Now, $script:phaseLabel.Text, $script:countValue.Text,
            $script:bytesValue.Text, $script:rateValue.Text, $script:etaValue.Text, $filename)
        $script:state.LastConsoleProgress = [datetime]::Now
    }
}

# Value: Summary count, error list, review list, or null.
function Format-SummaryCount {
    param($Value)
    if ($null -eq $Value) { return '--' }
    if ($Value -is [Array]) { return [string]$Value.Count }
    return [string]$Value
}

# Summary: Backend review verdict and counters, without inferring safety from exit alone.
function Update-OrganizerSummary {
    param($Summary)
    $script:state.LastSummary = $Summary
    if ([string](Get-EventValue $Summary 'mode' '') -like 'cleanup-*') { Update-CleanupSummary $Summary; return }
    if ((Get-EventValue $Summary 'mode' '') -eq 'what-if') {
        $total = Format-SummaryCount (Get-EventValue $Summary 'total')
        $bytes = Get-NonnegativeNumber (Get-EventValue $Summary 'bytes_total')
        $flagged = Format-SummaryCount (Get-EventValue $Summary 'online_or_recall_flagged')
        $omissions = @(Get-EventValue $Summary 'omissions' @()).Count
        $script:countValue.Text = $total + ' file'
        $script:bytesValue.Text = if ($null -ne $bytes) { Format-ByteCount $bytes } else { '--' }
        $script:summaryLabel.Text = 'Inventario: {0} file | Dimensione logica: {1} | OneDrive/recall: {2} | Collegamenti esclusi: {3}. Nessun contenuto letto.' -f $total, $script:bytesValue.Text, $flagged, $omissions
        Write-UiLog $script:summaryLabel.Text 'SIMULA'
        return
    }
    $completed = Format-SummaryCount (Get-EventValue $Summary 'completed')
    $total = Format-SummaryCount (Get-EventValue $Summary 'total')
    $duplicates = Format-SummaryCount (Get-EventValue $Summary 'duplicates')
    $unique = Format-SummaryCount (Get-EventValue $Summary 'unique_files')
    $review = Format-SummaryCount (Get-EventValue $Summary 'review_files')
    $errors = Format-SummaryCount (Get-EventValue $Summary 'errors')
    $script:summaryLabel.Text = 'Completati: {0}/{1}   |   Unici: {2}   |   Duplicati: {3}   |   Da rivedere: {4}   |   Errori: {5}' -f
        $completed, $total, $unique, $duplicates, $review, $errors
    $resultFolder = [string](Get-EventValue $Summary 'result_folder' '')
    if ($resultFolder) { Write-UiLog ('Risultato da copiare in immagini-pulite: ' + $resultFolder) 'OUTPUT' }
    Write-UiLog $script:summaryLabel.Text 'RIEPILOGO'
}

# Line: A background-reader event; stdout is interpreted as JSON only on the UI thread.
function Receive-OrganizerLine {
    param([PhotoOrganizer.OutputLine]$Line)
    Write-AppSessionLog $Line.Kind $Line.Text
    if ($Line.Kind -eq 'exit') {
        $script:state.ExitCode = [int]$Line.Text
        $script:state.ExitSeen = $true
        return
    }
    if ($Line.Kind -eq 'fault') {
        $script:state.HadError = $true
        Write-UiLog $Line.Text 'ERRORE'
        return
    }
    if ($Line.Kind -eq 'stderr') { Write-UiLog $Line.Text 'STDERR'; return }
    if ([string]::IsNullOrWhiteSpace($Line.Text)) { return }
    try { $event = ConvertFrom-Json -InputObject $Line.Text -ErrorAction Stop }
    catch { Write-UiLog $Line.Text 'LOG'; return }
    $type = [string](Get-EventValue $event 'event' (Get-EventValue $event 'type' 'log'))
    # Support the standard flat event and a nested payload envelope.
    $payload = Get-EventValue $event 'payload' $event
    switch ($type) {
        'scan' { $script:state.PendingProgress = $payload }
        'progress' { $script:state.PendingProgress = $payload }
        'summary' { Update-OrganizerSummary (Get-EventValue $payload 'summary' $payload) }
        'source_relocation_required' { $script:state.SourceRelocation = $payload }
        'sidecar_recovery_required' { $script:state.SidecarRecovery = $payload }
        'error' { $script:state.HadError = $true }
        'log' { }
        'match' { if ($script:state.Mode.StartsWith('cleanup-')) { Add-CleanupMatch $payload } }
        default { Write-UiLog $Line.Text 'EVENTO'; return }
    }
    $message = [string](Get-EventValue $payload 'message' '')
    if ($message) { Write-UiLog $message $(if ($type -eq 'error') { 'ERRORE' } else { 'INFO' }) }
    elseif ($type -eq 'error') { Write-UiLog $Line.Text 'ERRORE' }
}

function Complete-OrganizerWorkflow {
    $worker = $script:state.Worker
    $script:state.Worker = $null
    $worker.Dispose()
    $script:progressBar.Style = 'Continuous'
    $script:pauseButton.Text = '&Pausa'
    Set-UiBusy $false
    if ($null -ne $script:state.SidecarRecovery -and -not $script:state.ClosePending) {
        $request = $script:state.SidecarRecovery
        $script:state.SidecarRecovery = $null
        Set-UiStatus 'JSON danneggiati: recupero disponibile su conferma.' 'Amber'
        $examples = (@($request.sidecars) | Select-Object -First 3) -join "`r`n"
        $question = "Trovati {0} JSON mancanti o illeggibili, compatibili con un'interruzione del PC.`r`n`r`n{1}`r`n`r`nVuoi recuperarli dal checkpoint SQLite?`r`n`r`nIl tool verifica SHA-256 di originali e copie, salva un backup del database e conserva i byte dei JSON corrotti in .photo-organizer\sidecar-recovery prima di rigenerarli. I JSON validi ma modificati non vengono sovrascritti. Poi riprende il lavoro.`r`n`r`nSe i file da recuperare cambiano, verra richiesta una nuova conferma." -f $request.count, $examples
        $choice = [Windows.Forms.MessageBox]::Show($script:form, $question, 'Recupero JSON dopo interruzione', 'YesNo', 'Warning', 'Button2')
        if ($choice -eq 'Yes') {
            try { Start-OrganizerWorkflow 'relocate-source' -RecoveryHash $request.confirmation_hash }
            catch { Show-UiError $_ }
        } else { Write-UiLog 'Recupero JSON annullato: nessun sidecar sovrascritto.' }
        return
    }
    if ($null -ne $script:state.SourceRelocation -and -not $script:state.ClosePending) {
        $request = $script:state.SourceRelocation
        $script:state.SourceRelocation = $null
        Set-UiStatus 'La sorgente salvata e diversa: scegli come procedere.' 'Amber'
        $question = "Questa destinazione era associata a:`r`n{0}`r`n`r`nOra hai selezionato:`r`n{1}`r`n`r`nSi: verifica SHA-256 dei file gia elaborati e delle copie, aggiorna i percorsi e riprendi. Puo richiedere tempo e scaricare i file della cartella selezionata. Nessun originale viene modificato o eliminato.`r`n`r`nNo: scegli un'altra destinazione.`r`nAnnulla: non fare nulla." -f $request.old_source, $request.new_source
        $choice = [Windows.Forms.MessageBox]::Show($script:form, $question, 'Sorgente trasferita?', 'YesNoCancel', 'Question', 'Button3')
        try {
            if ($choice -eq 'Yes') { Start-OrganizerWorkflow 'relocate-source' }
            elseif ($choice -eq 'No') { $script:destinationBrowse.PerformClick() }
            else { Write-UiLog 'Trasferimento sorgente annullato: stato e file conservati.' }
        } catch { Show-UiError $_ }
        return
    }
    $summary = $script:state.LastSummary
    if ($script:state.Mode -eq 'relocate-source' -and $script:state.ExitCode -eq 0 -and
        -not $script:state.HadError -and (Get-EventValue $summary 'relocation_complete' $false) -and
        -not $script:state.ClosePending) {
        Write-UiLog 'Sorgente trasferita verificata. Riprendo le copie dai checkpoint esistenti.'
        try { Start-OrganizerWorkflow 'run' } catch { Show-UiError $_ }
        return
    }
    $stopped = (Get-EventValue $summary 'stopped' $false) -eq $true
    $ready = (Get-EventValue $summary 'ready_for_review' $false) -eq $true
    $summaryErrors = Get-EventValue $summary 'errors' 0
    $hasSummaryErrors = if ($summaryErrors -is [Array]) { $summaryErrors.Count -gt 0 } else {
        $numericErrors = Get-NonnegativeNumber $summaryErrors
        $null -ne $numericErrors -and $numericErrors -gt 0
    }
    if ($script:state.ForceStopped) { Set-UiStatus 'Processo interrotto su conferma. Verifica l''output prima di riprendere.' 'Amber' }
    elseif ($stopped -and $script:state.Mode.StartsWith('cleanup-')) { Set-UiStatus 'Pulizia in pausa. Riprendi il piano confermato oppure esegui una nuova simulazione.' 'Amber' }
    elseif ($stopped) { Set-UiStatus 'In pausa. Copia / Riprendi continua dai checkpoint del backend.' 'Amber' }
    elseif ($script:state.ExitCode -ne 0 -or $script:state.HadError -or $hasSummaryErrors) {
        Set-UiStatus ('Operazione conclusa con errori (codice {0}). Controlla il registro.' -f $script:state.ExitCode) 'Red'
    }
    elseif ($null -eq $summary) { Set-UiStatus 'Processo concluso senza riepilogo: risultato da verificare.' 'Amber' }
    elseif ($script:state.Mode -eq 'what-if') { Set-UiStatus 'Simulazione conclusa. Consulta il riepilogo prima della copia.' 'Green' }
    elseif ($script:state.Mode.StartsWith('cleanup-')) { Set-UiStatus 'Pulizia: consulta il riepilogo e i file conservati.' 'Green' }
    elseif ($ready) { Set-UiStatus 'Output pronto per la revisione. Per pulire gli originali usa il pannello 04.' 'Green' }
    else { Set-UiStatus 'Operazione conclusa. L''output richiede ancora una revisione.' 'Amber' }
    if ($ready -and -not $stopped -and -not $hasSummaryErrors -and -not $script:state.HadError -and $script:state.ExitCode -eq 0) {
        $script:progressBar.Value = 1000
    }
    Write-UiLog ($script:statusLabel.Text + ' | Uscita: ' + $script:state.ExitCode)
    if ($script:workflowTestMode) {
        try { Advance-WorkflowSmokeTest }
        catch {
            $script:state.SmokeError = $_.Exception.Message
            Write-UiLog $script:state.SmokeError 'TEST ERROR'
            $script:form.Close()
        }
    }
    if ($script:state.ClosePending) { $script:form.Close() }
}

# Directory: Only a generated test directory inside the toolbox.
function Get-FixtureHashes {
    param([string]$Directory)
    $hashes = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File -Recurse) {
        $relative = $file.FullName.Substring($Directory.Length)
        $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $hashes
}

# First: Original map of relative filenames to content checksums.
# Second: Map to compare without changing its files.
function Test-FixtureHashes {
    param([hashtable]$First, [hashtable]$Second)
    if ($First.Count -ne $Second.Count) { return $false }
    foreach ($key in $First.Keys) {
        if (-not $Second.ContainsKey($key) -or $First[$key] -ne $Second[$key]) { return $false }
    }
    return $true
}

# Exception: Failed GUI/worker invariants abort only this synthetic smoke run.
function Advance-WorkflowSmokeTest {
    $summary = $script:state.LastSummary
    if ($script:state.ExitCode -ne 0 -or $script:state.HadError -or $null -eq $summary) {
        throw 'Il test GUI non ha ricevuto un riepilogo valido dal worker.'
    }
    if ((Get-EventValue $summary 'total') -ne 4) { throw 'Inventario GUI inatteso.' }
    if ($script:state.WorkflowStep -eq 0) {
        if ([IO.Directory]::Exists($script:destinationBox.Text)) { throw 'Simula ha creato l''output.' }
    } else {
        if (-not (Get-EventValue $summary 'ready_for_review' $false) -or
            (Get-EventValue $summary 'unique_files') -ne 3 -or (Get-EventValue $summary 'duplicates') -ne 1) {
            throw 'Copia/verifica GUI non ha preservato quattro originali in tre output.'
        }
        $result = Join-Path $script:destinationBox.Text 'Risultato'
        $hashes = Get-FixtureHashes $result
        if ($script:state.WorkflowStep -eq 1) { $script:state.FirstOutputHashes = $hashes }
        elseif (-not (Test-FixtureHashes $script:state.FirstOutputHashes $hashes)) {
            throw 'Ripresa/verifica GUI ha modificato un output o sidecar.'
        }
        if ($script:state.WorkflowStep -ge 2 -and (Get-EventValue $summary 'resumed') -ne 4) {
            throw 'La ripresa GUI non ha riutilizzato tutte le copie.'
        }
    }
    $script:state.WorkflowResults += $summary
    $script:state.WorkflowStep++
    if ($script:state.WorkflowStep -lt 4) {
        if ($script:state.WorkflowStep -eq 3) {
            $script:aiOption.Checked = $true
            Start-OrganizerWorkflow 'verify-only'
        } else { Start-OrganizerWorkflow 'run' }
        return
    }
    $sourceHashes = Get-FixtureHashes $script:sourceBox.Text
    if (-not (Test-FixtureHashes $script:state.OriginalHashes $sourceHashes)) { throw 'Originali del test alterati.' }
    $verification = @{
        verified_at_utc = [datetime]::UtcNow.ToString('o')
        dpi = [PhotoOrganizer.Native]::GetDpiForWindow($script:form.Handle)
        gui_worker_modes = @('what-if', 'copy', 'resume', 'verify')
        original_bytes_unchanged = $true
        resumed_output_and_sidecar_bytes_unchanged = $true
        verify_with_changed_ai_toggle = $true
        real_archive_folders_processed = 0
        summaries = $script:state.WorkflowResults
    }
    $report = Join-Path $PSScriptRoot 'output\gui-workflow-verification.json'
    [IO.File]::WriteAllText($report, ($verification | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding($false)))
    Write-Host ('GUI_WORKFLOW_OK | Simula / Copia / Riprendi / Verifica | ' + $report)
    $script:form.Close()
}

# Exception: Only generated fixture creation or a worker startup can fail.
function Start-WorkflowSmokeTest {
    $fixtureRoot = Join-Path $PSScriptRoot ('temp\gui-workflow-' + [guid]::NewGuid().ToString('N'))
    $source = Join-Path $fixtureRoot 'sorgente di prova è locale'
    [void][IO.Directory]::CreateDirectory($source)
    $script:state.WorkflowRoot = $fixtureRoot
    $encoding = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $source 'nota è unicode.txt'), 'Synthetic fixture. Do not execute file contents.', $encoding)
    [IO.File]::WriteAllText((Join-Path $source 'allegato.json'), '{"synthetic":true}', $encoding)
    $bitmap = New-Object Drawing.Bitmap(32, 32)
    try { $bitmap.Save((Join-Path $source 'immagine.png'), [Drawing.Imaging.ImageFormat]::Png) }
    finally { $bitmap.Dispose() }
    [IO.File]::Copy((Join-Path $source 'immagine.png'), (Join-Path $source 'doppione.png'))
    $script:state.OriginalHashes = Get-FixtureHashes $source
    $script:sourceBox.Text = $source
    $script:destinationBox.Text = Join-Path $fixtureRoot 'review'
    $script:aiOption.Checked = $false
    $script:state.WorkflowStarted = $true
    Start-OrganizerWorkflow 'what-if'
}

# Exception: An unavailable destination or Explorer launch failure is surfaced.
function Open-OrganizerOutput {
    if ($script:smokeMode) { return }
    $destination = if ($null -ne $script:state.Worker) { $script:state.ActiveDestination } else {
        Resolve-DirectoryText $script:destinationBox.Text
    }
    if (-not [IO.Directory]::Exists($destination)) { throw 'La cartella di output non esiste ancora.' }
    $resultFolder = Join-Path $destination 'Risultato'
    if ([IO.Directory]::Exists($resultFolder)) { $destination = $resultFolder }
    # Only Explorer is intentionally visible; workers always use CreateNoWindow.
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $destination
    $info.UseShellExecute = $true
    $opened = [Diagnostics.Process]::Start($info)
    if ($null -ne $opened) { $opened.Dispose() }
}

# EventArgs: FormClosing arguments; cancellation keeps the queue and UI alive.
function Confirm-OrganizerClose {
    param([Windows.Forms.FormClosingEventArgs]$EventArgs)
    if ($null -eq $script:state.Worker) { return }
    $EventArgs.Cancel = $true
    if (-not $script:state.ClosePending) {
        $answer = [Windows.Forms.MessageBox]::Show($script:form,
            'È in corso un''elaborazione. Richiedere una pausa e chiudere quando il backend raggiunge un punto sicuro?',
            'Pausa e chiusura', 'YesNo', 'Question', 'Button2')
        if ($answer -ne 'Yes') { return }
        try {
            Request-OrganizerPause
            $script:state.ClosePending = $true
            Set-UiStatus 'Chiusura in attesa della pausa del backend. Richiudi per le opzioni di arresto.' 'Amber'
        } catch { Show-UiError $_ }
        return
    }
    $answer = [Windows.Forms.MessageBox]::Show($script:form,
        'Il backend sta ancora terminando. Forzare l''arresto e chiudere? Le copie completate restano nell''output; verifica prima di riprendere. Eventuali processi AI residui potrebbero richiedere una chiusura manuale.',
        'Conferma arresto forzato', 'YesNo', 'Warning', 'Button2')
    if ($answer -eq 'Yes') {
        try {
            $script:state.Worker.StopAfterConfirmation()
            $script:state.ForceStopped = $true
            Set-UiStatus 'Arresto confermato. Attendo la chiusura dei flussi del processo.' 'Amber'
            Write-UiLog 'Arresto forzato del solo processo backend confermato dall''utente.' 'ARRESTO'
        } catch { Show-UiError $_ }
    }
}

# Caption: Accessible caption for the path field.
# Box: Text box placed in the adaptive row.
# Browse: Folder-picker button placed beside the field.
function New-PathRow {
    param([string]$Caption, [Windows.Forms.Control]$Box, [Windows.Forms.Button]$Browse)
    $table = New-UiTable 2
    $table.ColumnStyles.Clear()
    [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$table.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
    Add-UiRow $table (New-UiLabel $Caption -Bold) 2
    $table.RowCount++
    [void]$table.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
    $Box.Dock = 'Fill'
    if ($Box -is [Windows.Forms.TextBox]) { $Box.BorderStyle = 'FixedSingle' }
    $Box.Margin = New-Object Windows.Forms.Padding(0, 6, 12, 10)
    $Box.AccessibleName = $Caption
    $Browse.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8)
    $table.Controls.Add($Box, 0, 1)
    $table.Controls.Add($Browse, 1, 1)
    return $table
}

# Caption: Metric label.
# Value: Label which will receive live values.
function New-MetricCell {
    param([string]$Caption, [Windows.Forms.Label]$Value)
    $cell = New-UiTable
    $cell.Dock = 'Fill'
    $cell.Margin = New-Object Windows.Forms.Padding(0, 4, 16, 10)
    Add-UiRow $cell (New-UiLabel $Caption -Size 9 -Color $script:palette.Muted)
    Add-UiRow $cell $Value
    return $cell
}

$script:form = New-Object PhotoOrganizer.DpiForm
$script:form.SuspendLayout()
$script:form.Text = $script:branding.product_name + ' | ' + $script:branding.publisher_name
if ($null -ne $script:brandIcon) { $script:form.Icon = $script:brandIcon }
$script:form.Font = New-AppFont 10
$script:form.BackColor = $script:palette.Canvas
$script:form.ClientSize = New-Object Drawing.Size(1020, 860)
$script:form.MinimumSize = New-Object Drawing.Size(740, 540)
$script:form.StartPosition = 'CenterScreen'
$script:form.Icon = [Drawing.SystemIcons]::Application
$script:form.KeyPreview = $true
$script:toolTip = New-Object Windows.Forms.ToolTip
$script:toolTip.AutoPopDelay = 15000

$root = New-UiTable
$root.Dock = 'Fill'
$root.AutoSize = $false
$root.RowCount = 3
$root.RowStyles.Clear()
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
$script:form.Controls.Add($root)

$header = New-UiTable 3
$header.BackColor = $script:palette.Navy
$header.Tag = 'header'
$header.Padding = New-Object Windows.Forms.Padding(28, 20, 28, 16)
$header.ColumnStyles.Clear()
[void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
[void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
[void]$header.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize')))
$header.RowCount = 1
[void]$header.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
$headerTitles = New-UiTable
Add-UiRow $headerTitles (New-UiLabel 'VIBEWARE  /  AI TOOLBOX  /  UMBERTO GIACOBBI' -Size 9 -Bold -Color $script:palette.Cyan)
Add-UiRow $headerTitles (New-UiLabel 'Foto ordinate. Originali al sicuro.' -Size 18 -Bold -Color ([Drawing.Color]::White))
Add-UiRow $headerTitles (New-UiLabel 'Simula, copia e riprendi. Poi verifica il risultato.' -Size 10 -Color ([Drawing.ColorTranslator]::FromHtml('#BBCCDF')))
$headerLogo = New-VibeWareLogo -Size 88
if ($null -ne $headerLogo) {
    $headerLogo.Anchor = 'Left'
    $headerLogo.Margin = New-Object Windows.Forms.Padding(0, 0, 18, 0)
    $header.Controls.Add($headerLogo, 0, 0)
}
$header.Controls.Add($headerTitles, 1, 0)
$script:sessionLabel = New-UiLabel 'PRONTO' -Size 9 -Bold -Color $script:palette.Cyan
$script:sessionLabel.Anchor = 'Top,Right'
$script:sessionLabel.Dock = 'None'
$script:sessionLabel.Margin = New-Object Windows.Forms.Padding(20, 7, 0, 0)
$header.Controls.Add($script:sessionLabel, 2, 0)
$root.Controls.Add($header, 0, 0)

$script:workspace = New-Object PhotoOrganizer.StableScrollPanel
$workspace = $script:workspace
$workspace.Dock = 'Fill'
$workspace.AutoScroll = $true
$workspace.Margin = New-Object Windows.Forms.Padding(0)
$workspace.Padding = New-Object Windows.Forms.Padding(22, 18, 22, 4)
$root.Controls.Add($workspace, 0, 1)
$stack = New-UiTable
$workspace.Controls.Add($stack)

$folders = New-UiCard '01   Cartelle'
$script:sourceBox = New-PathCombo $script:pathHistory.Sources
$script:destinationBox = New-PathCombo $script:pathHistory.Destinations
$script:sourceBox.Text = $script:pathHistory.Source
$script:destinationBox.Text = $script:pathHistory.Destination
$script:state.DestinationCustomized = -not [string]::IsNullOrWhiteSpace($script:destinationBox.Text)
$script:sourceBrowse = New-UiButton '&Sfoglia...'
$script:destinationBrowse = New-UiButton 'S&foglia...'
Add-UiRow $folders.Content (New-PathRow 'Cartella di origine' $script:sourceBox $script:sourceBrowse)
Add-UiRow $folders.Content (New-PathRow 'Cartella di destinazione' $script:destinationBox $script:destinationBrowse)
Add-UiRow $folders.Content (New-UiLabel 'La destinazione proposta segue il nome dell''origine finché non la personalizzi.' -Size 9 -Color $script:palette.Muted)
Add-UiRow $stack $folders.Panel

$options = New-UiCard '02   Preferenze e tutela degli originali'
$script:aiOption = New-Object PhotoOrganizer.ThemeCheckBox
$script:aiOption.Text = 'Usa AI locale per organizzare le foto'
$script:aiOption.Checked = $true
$script:aiOption.AutoSize = $true
$script:aiOption.Dock = 'Top'
$script:aiOption.BackColor = [Drawing.Color]::White
$script:aiOption.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8)
Add-UiRow $options.Content $script:aiOption
$script:transcribeOption = New-Object PhotoOrganizer.ThemeCheckBox
$script:transcribeOption.Text = 'Trascrivi audio e video in SRT (locale, CPU; setup su richiesta)'
$script:transcribeOption.AutoSize = $true; $script:transcribeOption.Dock = 'Top'
$script:transcribeOption.Checked = $false
$script:transcribeOption.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8)
Add-UiRow $options.Content $script:transcribeOption
$script:videoDescriptionOption = New-Object PhotoOrganizer.ThemeCheckBox
$script:videoDescriptionOption.Text = 'Descrivi i video con AI locale (JSON separato; campionamento configurabile)'
$script:videoDescriptionOption.AutoSize = $true; $script:videoDescriptionOption.Dock = 'Top'
$script:videoDescriptionOption.Checked = $false
$script:videoDescriptionOption.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8)
Add-UiRow $options.Content $script:videoDescriptionOption
Add-UiRow $options.Content (New-UiLabel 'OneDrive gestisce i file in background; nessun pin/sync modificato.' -Size 9 -Color $script:palette.Muted)
Add-UiRow $options.Content (New-UiLabel 'La copia lascia gli originali intatti. Il pannello 04 sposta nel Cestino solo copie verificate, su conferma.' -Size 10 -Bold -Color $script:palette.Green)
$script:optionsButton = New-UiButton 'Opzioni / Setup'
$script:optionsButton.Add_Click({ try { Show-ToolboxOptions } catch { Show-UiError $_ } })
$aboutButton = New-UiButton 'Informazioni / About'
$aboutButton.Add_Click({ try { Show-ToolboxAbout } catch { Show-UiError $_ } })
$preferenceButtons = New-Object Windows.Forms.FlowLayoutPanel
$preferenceButtons.AutoSize = $true
$preferenceButtons.Dock = 'Top'
$preferenceButtons.WrapContents = $false
$preferenceButtons.Margin = New-Object Windows.Forms.Padding(0)
$preferenceButtons.Controls.Add($script:optionsButton)
$preferenceButtons.Controls.Add($aboutButton)
Add-UiRow $options.Content $preferenceButtons
Add-UiRow $options.Content (New-UiLabel 'Copia solo la cartella Risultato in immagini-pulite. I checkpoint restano in .photo-organizer, fuori dal risultato.' -Size 9 -Color $script:palette.Muted)
Add-UiRow $stack $options.Panel

$activity = New-UiCard '03   Attività'
$actions = New-Object Windows.Forms.FlowLayoutPanel
$actions.AutoSize = $true
$actions.AutoSizeMode = 'GrowAndShrink'
$actions.Dock = 'Top'
$actions.WrapContents = $true
$actions.Margin = New-Object Windows.Forms.Padding(0)
$actions.BackColor = [Drawing.Color]::Transparent
$script:simulateButton = New-UiButton 'Si&mula'
$script:copyButton = New-UiButton '&Copia / Riprendi' -Primary
$script:pauseButton = New-UiButton '&Pausa'
$script:verifyButton = New-UiButton '&Verifica output'
$script:openButton = New-UiButton '&Apri output'
foreach ($button in @($script:simulateButton, $script:copyButton, $script:pauseButton, $script:verifyButton, $script:openButton)) {
    $actions.Controls.Add($button)
}
Add-UiRow $activity.Content $actions
$activityTabs = New-Object PhotoOrganizer.ThemeTabControl
$activityTabs.Dock = 'Top'
$activityTabs.Height = 330
$activityTabs.Margin = New-Object Windows.Forms.Padding(0, 8, 0, 0)
$activityTabs.Multiline = $true
$activityTabs.AccessibleName = 'Avanzamento e registro eventi'
$progressTab = New-Object Windows.Forms.TabPage
$progressTab.Text = 'Avanzamento'
$progressTab.Tag = 'surface'
$progressTab.AutoScroll = $true
$progressTab.Padding = New-Object Windows.Forms.Padding(14)
$logTab = New-Object Windows.Forms.TabPage
$logTab.Text = 'Registro eventi'
$logTab.Tag = 'surface'
$logTab.Padding = New-Object Windows.Forms.Padding(14)
[void]$activityTabs.TabPages.Add($progressTab)
[void]$activityTabs.TabPages.Add($logTab)
$progressContent = New-UiTable
$progressTab.Controls.Add($progressContent)
Add-UiRow $activity.Content $activityTabs
# Both pages keep their controls alive: switching tabs never resets the job or log.
$script:phaseLabel = New-UiLabel 'Pronto per la simulazione' -Size 11 -Bold
$script:phaseLabel.AutoSize = $false; $script:phaseLabel.AutoEllipsis = $true
$script:phaseLabel.Height = 32
Add-UiRow $progressContent $script:phaseLabel
$script:progressBar = New-Object Windows.Forms.ProgressBar
$script:progressBar.Dock = 'Top'
$script:progressBar.Height = 10
$script:progressBar.Maximum = 1000
$script:progressBar.MarqueeAnimationSpeed = 25
$script:progressBar.Margin = New-Object Windows.Forms.Padding(0, 3, 0, 9)
Add-UiRow $progressContent $script:progressBar
$script:fileLabel = New-UiLabel 'Nessun processo avviato.' -Size 9 -Color $script:palette.Muted
$script:fileLabel.AutoSize = $false
$script:fileLabel.AutoEllipsis = $true
$script:fileLabel.Height = 24
Add-UiRow $progressContent $script:fileLabel
$metrics = New-UiTable 4
$metrics.Dock = 'Top'
$metrics.RowCount = 1
[void]$metrics.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize')))
$script:countValue = New-UiLabel '-- / --' -Size 13 -Bold
$script:bytesValue = New-UiLabel '--' -Size 13 -Bold
$script:rateValue = New-UiLabel '--' -Size 13 -Bold
$script:etaValue = New-UiLabel '--' -Size 13 -Bold
$metrics.Controls.Add((New-MetricCell 'FILE ELABORATI' $script:countValue), 0, 0)
$metrics.Controls.Add((New-MetricCell 'DATI COPIATI' $script:bytesValue), 1, 0)
$metrics.Controls.Add((New-MetricCell 'VELOCITÀ' $script:rateValue), 2, 0)
$metrics.Controls.Add((New-MetricCell 'TEMPO RESIDUO' $script:etaValue), 3, 0)
Add-UiRow $progressContent $metrics
$script:elapsedLabel = New-UiLabel 'Tempo trascorso: --' -Size 9 -Color $script:palette.Muted
Add-UiRow $progressContent $script:elapsedLabel
$script:summaryLabel = New-UiLabel 'Il riepilogo mostrerà completati, duplicati, file da rivedere ed errori.' -Size 9 -Color $script:palette.Muted
Add-UiRow $progressContent $script:summaryLabel
$script:logBox = New-Object Windows.Forms.RichTextBox
$script:logBox.Multiline = $true
$script:logBox.ReadOnly = $true
$script:logBox.MaxLength = [int]::MaxValue
$script:logBox.TabStop = $false
$script:logBox.BorderStyle = 'FixedSingle'
$script:logBox.DetectUrls = $false
$script:logBox.HideSelection = $false
$script:logBox.WordWrap = $false
$script:logBox.BackColor = $script:palette.Navy
$script:logBox.ForeColor = [Drawing.ColorTranslator]::FromHtml('#D8E7F6')
$script:logBox.Font = New-AppFont 9
$script:logBox.Tag = 'console'
$script:logBox.Dock = 'Fill'
$script:logBox.ScrollBars = 'Both'
$script:logBox.AccessibleName = 'Registro attività del backend'
$logTab.Controls.Add($script:logBox)
Add-UiRow $stack $activity.Panel
Add-CleanupPanel $stack

$footer = New-UiTable
$footer.BackColor = [Drawing.Color]::White
$footer.Tag = 'surface'
$footer.Padding = New-Object Windows.Forms.Padding(26, 10, 26, 8)
$script:statusLabel = New-UiLabel 'Seleziona l''origine, poi avvia una simulazione.' -Size 9
$script:statusLabel.Margin = New-Object Windows.Forms.Padding(0)
Add-UiRow $footer $script:statusLabel
Add-UiRow $footer (New-PublisherCredit)
Add-UiRow $footer (New-UiLabel 'VibeWare = Human intent, AI, and plenty of tokens ;-)' -Size 9 -Color $script:palette.Muted)
$root.Controls.Add($footer, 0, 2)

$script:toolTip.SetToolTip($script:simulateButton, 'Mostra il piano con --what-if. Non avvia una copia.')
$script:toolTip.SetToolTip($script:copyButton, 'Avvia --run oppure riprende dai checkpoint presenti nell''output.')
$script:toolTip.SetToolTip($script:pauseButton, 'Richiede una pausa cooperativa senza terminare il processo.')
$script:toolTip.SetToolTip($script:verifyButton, 'Controlla l''output con --verify-only.')
$script:toolTip.SetToolTip($script:destinationBox, 'Percorso modificabile. Origine e destinazione non possono contenersi.')
$script:sourceBox.Add_TextChanged({ Update-DefaultDestination })
$script:destinationBox.Add_TextChanged({
    if (-not $script:state.SettingDestination) {
        $script:state.DestinationCustomized = -not [string]::IsNullOrWhiteSpace($script:destinationBox.Text)
    }
})
$script:sourceBrowse.Add_Click({ try { Select-Directory $script:sourceBox 'Seleziona la cartella di origine' } catch { Show-UiError $_ } })
$rememberPaths = {
    if ($null -eq $script:state.Worker) {
        try { Remember-PathSelection $script:sourceBox.Text $script:destinationBox.Text }
        catch { Write-UiLog ('Salvataggio percorsi: ' + $_.Exception.Message) 'ERRORE' }
    }
}
$script:sourceBox.Add_Leave($rememberPaths)
$script:destinationBox.Add_Leave($rememberPaths)
$script:destinationBrowse.Add_Click({ try { Select-Directory $script:destinationBox 'Seleziona la cartella di destinazione' } catch { Show-UiError $_ } })
$script:simulateButton.Add_Click({ try { Start-OrganizerWorkflow 'what-if' } catch { Show-UiError $_ } })
$script:copyButton.Add_Click({ try { Start-OrganizerWorkflow 'run' } catch { Show-UiError $_ } })
$script:verifyButton.Add_Click({ try { Start-OrganizerWorkflow 'verify-only' } catch { Show-UiError $_ } })
$script:pauseButton.Add_Click({ try { Request-OrganizerPause } catch { Show-UiError $_ } })
$script:openButton.Add_Click({ try { Open-OrganizerOutput } catch { Show-UiError $_ } })
$script:form.Add_FormClosing({
    param($sender, $eventArgs)
    Confirm-OrganizerClose $eventArgs
    if (-not $eventArgs.Cancel) { & $rememberPaths }
})
$script:form.Add_HandleCreated({ Set-WindowTheme $script:form })
Update-DefaultDestination
Set-UiBusy $false

$script:uiTimer = New-Object Windows.Forms.Timer
$script:themeTimer = New-Object Windows.Forms.Timer
$script:themeTimer.Interval = 2000
$script:themeTimer.Add_Tick({
    if ($script:uiPreferences.Theme -ne 'System') { return }
    $currentTheme = Get-AppTheme
    if ($currentTheme -eq $script:effectiveTheme) { return }
    # Poll on the UI thread and repaint only when the system theme actually changes.
    foreach ($window in @([Windows.Forms.Application]::OpenForms)) { Set-AppAppearance $window }
})
$script:uiTimer.Interval = 100
$script:uiTimer.Add_Tick({
    if ($script:state.TimerBusy) { return }
    if ($null -eq $script:state.Worker) { Flush-UiLog; return }
    $script:state.TimerBusy = $true
    try {
        $budget = [Diagnostics.Stopwatch]::StartNew()
        $processed = 0
        $line = $null
        $script:workspace.SuppressFocusScroll = $true
        while ($processed -lt 200 -and $budget.ElapsedMilliseconds -lt 25 -and
            $script:state.Worker.TryTake([ref]$line)) {
            try { Receive-OrganizerLine $line }
            catch { $script:state.HadError = $true; Write-UiLog $_.Exception.Message 'ERRORE' }
            $processed++
        }
        # The exit event is queued after both streams drain; Task completion then
        # guarantees no output is discarded and disposal cannot race the readers.
        if ($null -ne $script:state.PendingProgress) {
            Update-OrganizerProgress $script:state.PendingProgress
            $script:state.PendingProgress = $null
        }
        Flush-UiLog
        if ($script:state.ExitSeen -and $script:state.Worker.IsCompleted) { Complete-OrganizerWorkflow }
    } finally { $script:workspace.SuppressFocusScroll = $false; $script:state.TimerBusy = $false }
})

$script:smokeTimer = New-Object Windows.Forms.Timer
$script:smokeTimer.Interval = 650
$script:smokeTimer.Add_Tick({
    $script:smokeTimer.Stop()
    try {
        $script:form.PerformLayout()
        $script:form.Refresh()
        $outputDirectory = Join-Path $PSScriptRoot 'output'
        [void][IO.Directory]::CreateDirectory($outputDirectory)
        $imagePath = Join-Path $outputDirectory 'gui-smoke.png'
        $bitmap = New-Object Drawing.Bitmap($script:form.Width, $script:form.Height)
        try {
            $script:form.DrawToBitmap($bitmap, (New-Object Drawing.Rectangle(0, 0, $bitmap.Width, $bitmap.Height)))
            $bitmap.Save($imagePath, [Drawing.Imaging.ImageFormat]::Png)
        } finally { $bitmap.Dispose() }
        Write-Host ('UI_SMOKE_OK | DPI {0} | {1} x {2} | {3}' -f
            [PhotoOrganizer.Native]::GetDpiForWindow($script:form.Handle), $script:form.Width, $script:form.Height, $imagePath)
    } catch {
        $script:state.SmokeError = $_.Exception.Message
        Write-Host ('UI_SMOKE_ERROR | ' + $script:state.SmokeError)
    } finally { $script:form.Close() }
})
$script:form.Add_Shown({
    $workingArea = [Windows.Forms.Screen]::FromControl($script:form).WorkingArea
    $script:form.Width = [Math]::Min($script:form.Width, $workingArea.Width - 32)
    $script:form.Height = [Math]::Min($script:form.Height, $workingArea.Height - 32)
    $script:form.Left = $workingArea.Left + [int](($workingArea.Width - $script:form.Width) / 2)
    $script:form.Top = $workingArea.Top + [int](($workingArea.Height - $script:form.Height) / 2)
    $script:form.ActiveControl = $script:sourceBox
    $script:workspace.AutoScrollPosition = New-Object Drawing.Point(0, 0)
    if ($script:dialogSmokeMode) {
        try { Invoke-DialogSmokeTests }
        catch { $script:state.SmokeError = $_.Exception.Message; Write-Host ('DIALOG_SMOKE_ERROR | ' + $script:state.SmokeError) }
        finally { $script:form.Close() }
    } elseif ($script:workflowTestMode) {
        try { Start-WorkflowSmokeTest }
        catch {
            $script:state.SmokeError = $_.Exception.Message
            Write-Host ('GUI_WORKFLOW_ERROR | ' + $script:state.SmokeError)
            $script:form.Close()
        }
    } elseif ($script:smokeMode) {
        Set-UiStatus 'Test interfaccia: nessuna lettura dell''origine, copia, AI o download.'
        Write-UiLog 'Test di rendering. Nessun processo backend verrà avviato.' 'TEST'
        $script:smokeTimer.Start()
    } else {
        Write-UiLog ('Registro persistente: ' + $script:guiLogPath)
        if ($script:uiPreferences.AutoInstallMissingFont -and $script:preferredFontMissing) {
            Show-ToolboxOptions -InstallMissingFont
        }
        Write-UiLog 'Pronto. La modalità iniziale è Simula; AI attiva. OneDrive gestisce i file in background.'
        if (-not $dpiEnabled) { Write-UiLog 'Windows non ha accettato il contesto DPI per monitor.' 'AVVISO' }
    }
    $script:uiTimer.Start()
    $script:themeTimer.Start()
})
$script:form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
$script:form.ResumeLayout($true)
Set-AppAppearance $script:form

try { [Windows.Forms.Application]::Run($script:form) }
finally {
    $script:themeTimer.Stop()
    $script:themeTimer.Dispose()
    $script:uiTimer.Stop()
    $script:uiTimer.Dispose()
    $script:smokeTimer.Dispose()
    $script:toolTip.Dispose()
    if ($null -ne $script:state.Worker) { $script:state.Worker.Dispose() }
    $script:form.Dispose()
    foreach ($font in $script:fontCache.Values) { $font.Dispose() }
    if ($null -ne $script:brandIcon) { $script:brandIcon.Dispose() }
    if ($null -ne $script:vibeWareLogo) { $script:vibeWareLogo.Dispose() }
}
if ($script:workflowTestMode -and -not $script:state.WorkflowStarted -and $null -eq $script:state.SmokeError) {
    $script:state.SmokeError = 'Il test workflow non è stato avviato.'
}
if ($script:workflowTestMode -and $script:state.WorkflowStep -ne 4 -and $null -eq $script:state.SmokeError) {
    $script:state.SmokeError = 'Il test workflow non ha completato tutte le fasi.'
}
if ($null -ne $script:state.SmokeError) { exit 1 }
