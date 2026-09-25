#!/bin/zsh
# Fails the build when Show Bar would stay awake or hold unbounded images while idle.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
live=0
if [[ "${1:-}" == "--live" ]]; then
  live=1
fi

python3 - "$root" <<'PY'
import re, sys
from pathlib import Path

root = Path(sys.argv[1])
sources = sorted((root / "Sources").glob("*.swift"))
errors = []

timer_re = re.compile(r"(?:withTimeInterval|timeInterval):\s*([^,\)]+)")
mark_re = re.compile(r"resource:\s*(idle|active)\s+([0-9.]+)")
memory_re = re.compile(r"resource:\s*memory\s+([0-9]+)")
number_re = re.compile(r"\b(\d+)\b")

def interval(expr: str):
    expr = expr.strip()
    if re.fullmatch(r"[0-9.]+", expr):
        return float(expr)
    parts = expr.split("/")
    if len(parts) == 2 and re.fullmatch(r"[0-9.]+", parts[0].strip()) and re.fullmatch(r"[0-9.]+", parts[1].strip()):
        denom = float(parts[1])
        if denom == 0:
            return None
        return float(parts[0]) / denom
    return None

for path in sources:
    lines = path.read_text().splitlines()
    text = "\n".join(lines)
    for banned in ("beginActivity", "IOPMAssertion", "SCStream("):
        if banned in text:
            errors.append(f"{path.name}: {banned} keeps the Mac awake or holds a capture stream")
    if "tapCreate(" in text and "enable: false" not in text:
        errors.append(f"{path.name}: an event tap is created without a path that turns it off")
    for index, line in enumerate(lines, start=1):
        match = timer_re.search(line)
        if not match:
            continue
        window = "\n".join(lines[max(0, index - 7):index])
        mark = None
        for previous in reversed(window.splitlines()):
            found = mark_re.search(previous)
            if found:
                mark = found
                break
        if not mark:
            errors.append(f"{path.name}:{index}: repeating timer has no resource budget")
            continue
        kind, declared = mark.group(1), float(mark.group(2))
        expr = match.group(1).strip()
        if expr == "interval":
            if "schedulePoll(interval: 1.0)" not in text or "schedulePoll(interval: 0.12)" not in text:
                errors.append(f"{path.name}:{index}: pointer poll must idle at 1.0s and speed up to 0.12s only at the Dock")
            actual = 1.0
        else:
            actual = interval(expr)
        if actual is None:
            errors.append(f"{path.name}:{index}: timer interval is not a plain number")
            continue
        if expr != "interval" and abs(actual - declared) > 0.002:
            errors.append(f"{path.name}:{index}: timer is {actual:.3f}s but the budget says {declared:.3f}s")
        if kind == "idle" and declared < 1.0:
            errors.append(f"{path.name}:{index}: idle timer is faster than once a second")
        if kind == "active" and declared < 1.0 / 60.0 - 0.001:
            errors.append(f"{path.name}:{index}: active timer is faster than 60 times a second")
        if kind == "active" and ".invalidate()" not in text:
            errors.append(f"{path.name}: active timer has no invalidate()")
    for index, line in enumerate(lines, start=1):
        mark = memory_re.search(line)
        if not mark:
            continue
        cap = int(mark.group(1))
        following = "\n".join(lines[index:index + 3])
        numbers = [int(item) for item in number_re.findall(following)]
        if cap not in numbers:
            errors.append(f"{path.name}:{index}: memory budget {cap} is not the stored limit")
        if "shotLimit" in following and cap > 8:
            errors.append(f"{path.name}:{index}: screenshot shelf holds more than 8 images")
        if "limit" in following and "shotLimit" not in following and cap > 100:
            errors.append(f"{path.name}:{index}: clipboard history holds more than 100 items")

if errors:
    print("Resource check failed")
    for error in errors:
        print(f"- {error}")
    sys.exit(1)
print("Resource check passed")
print("- Idle timers are one second or slower")
print("- Fast timers exist only while a preview, crop, or permissions window is open")
print("- Event taps turn off, and screenshot memory stays capped")
PY

if [[ "$live" -eq 0 ]]; then
  exit 0
fi

pid="$(pgrep -x ShowBar || true)"
if [[ -z "$pid" ]]; then
  echo "Live resource check failed: Show Bar is not running. Leave it idle in the menu bar, away from the Dock, and run this again."
  exit 1
fi

count="$(printf '%s\n' "$pid" | wc -l | tr -d ' ')"
if [[ "$count" != "1" ]]; then
  echo "Live resource check failed: more than one Show Bar is running."
  exit 1
fi

cpu_sum=0
rss_max=0
samples=0
for _ in 1 2 3 4 5 6; do
  stats="$(ps -p "$pid" -o %cpu=,rss= || true)"
  if [[ -z "$stats" ]]; then
    echo "Live resource check failed: Show Bar quit during the sample."
    exit 1
  fi
  cpu="${stats%%.*}"
  cpu="${cpu// /}"
  rss="${stats##* }"
  rss="${rss// /}"
  cpu_sum=$((cpu_sum + cpu))
  if [[ "$rss" -gt "$rss_max" ]]; then
    rss_max="$rss"
  fi
  samples=$((samples + 1))
  sleep 1
done

cpu_avg=$((cpu_sum / samples))
rss_mb=$((rss_max / 1024))
echo "Live sample: about ${cpu_avg}% CPU, ${rss_mb} MB resident"
if [[ "$cpu_avg" -gt 5 || "$rss_mb" -gt 180 ]]; then
  echo "Live resource check failed. Idle Show Bar must stay near 0% CPU and under 180 MB. Move the pointer away from the Dock and run this again."
  exit 1
fi
echo "Live resource check passed"
