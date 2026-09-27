import json
import subprocess

with open("tests/v22-vectors.json") as source:
    vectors = json.load(source)["vectors"]
result = subprocess.run(
    ["build/v22/check-sanitized"],
    input="\n".join(vector["input"] for vector in vectors) + "\n",
    text=True, capture_output=True, check=True,
)
if result.stderr:
    raise SystemExit(result.stderr)
if result.stdout.splitlines() != [vector["digest"] for vector in vectors]:
    raise SystemExit("Reference digest mismatch")
print(f"ASan/UBSan: {len(vectors)} reference vectors passed")
