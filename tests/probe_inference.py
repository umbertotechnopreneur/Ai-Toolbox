"""Manual synthetic-image compatibility probe; no archive images are opened."""

import base64
import io
import json
import subprocess

from PIL import Image, ImageDraw

import ai_toolbox as toolbox


# Exceptions: local engine startup or HTTP failures stop this diagnostic run.
def main():
    config = toolbox.configuration()
    image = Image.new("RGB", (512, 512), "white")
    ImageDraw.Draw(image).rectangle((80, 80, 430, 430), fill="red")
    stream = io.BytesIO()
    image.save(stream, format="JPEG")
    image_url = "data:image/jpeg;base64," + base64.b64encode(stream.getvalue()).decode("ascii")
    prompt = (toolbox.ROOT / "config/catalog-prompt.txt").read_text(encoding="utf-8")
    with toolbox.running_server(config) as endpoint:
        gpu = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total", "--format=csv,noheader"], capture_output=True, text=True)
        print("GPU with loaded model:", gpu.stdout.strip())
        for response_format in (
            {"type": "json_schema", "schema": toolbox.SCHEMA},
            {"type": "json_object", "schema": toolbox.SCHEMA},
            {"type": "json_schema", "json_schema": {"name": "photo_catalog", "schema": toolbox.SCHEMA, "strict": True}},
        ):
            payload = {"model": config["model_alias"], "temperature": 0, "seed": 0, "max_tokens": 400,
                       "response_format": response_format,
                       "messages": [{"role": "system", "content": prompt},
                                    {"role": "user", "content": [{"type": "image_url", "image_url": {"url": image_url}},
                                                                   {"type": "text", "text": "Catalog this synthetic image."}]}]}
            response = toolbox.local_request(endpoint + "/v1/chat/completions", payload, 120)
            print(json.dumps({"format": response_format["type"], "nested_schema": "json_schema" in response_format,
                              "choice": response["choices"][0]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
