#!/usr/bin/env python3
# PPM diff budget for A/B pairs (plans/DISTANCE.md D3 seam check):
# reports the share of pixels differing at all, the share differing by
# more than a per-channel threshold, and the max channel delta.
# usage: ppmdiff.py <a.ppm> <b.ppm> [threshold]
import sys


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    # P6\n<w> <h>\n255\n — header is three whitespace-separated lines.
    parts = data.split(b"\n", 3)
    magic, dims, maxv = parts[0], parts[1].split(), parts[2]
    assert magic == b"P6" and maxv == b"255", path
    w, h = int(dims[0]), int(dims[1])
    return w, h, parts[3]


def main():
    a_path, b_path = sys.argv[1], sys.argv[2]
    thresh = int(sys.argv[3]) if len(sys.argv) > 3 else 8
    w, h, a = read_ppm(a_path)
    w2, h2, b = read_ppm(b_path)
    assert (w, h) == (w2, h2), "size mismatch"
    n = w * h
    diff = 0
    over = 0
    maxd = 0
    for i in range(0, n * 3, 3):
        d = max(abs(a[i] - b[i]), abs(a[i + 1] - b[i + 1]), abs(a[i + 2] - b[i + 2]))
        if d:
            diff += 1
            if d > thresh:
                over += 1
            if d > maxd:
                maxd = d
    print(f"{a_path} vs {b_path}:")
    print(f"  pixels differing: {diff}/{n} ({100.0 * diff / n:.2f}%)")
    print(f"  delta > {thresh}: {over} ({100.0 * over / n:.3f}%), max delta {maxd}")


if __name__ == "__main__":
    main()
