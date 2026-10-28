"""#160 接缝 A 取证：比较几张截图在同一裁剪框内的变化像素数。

用法（本机 python 没有 Pillow，用 uv 临时带上）：
  uv run -q --with pillow python -I tools/frame_diff.py --box L,T,R,B a.png b.png [c.png ...]
每张图与第一张比较，输出差异包围盒与灰度差超过阈值的像素数。
裁剪框只框住模型，排除 UI、水面和角色；镜头移动过时结果无效。
"""
import argparse

from PIL import Image, ImageChops


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--box', required=True, help='裁剪框 left,top,right,bottom（像素）')
    ap.add_argument('--threshold', type=int, default=25, help='灰度差阈值，默认 25')
    ap.add_argument('frames', nargs='+')
    a = ap.parse_args()
    if len(a.frames) < 2:
        ap.error('至少给两张截图')
    box = tuple(int(v) for v in a.box.split(','))
    base = Image.open(a.frames[0]).convert('L').crop(box)
    for f in a.frames[1:]:
        d = ImageChops.difference(base, Image.open(f).convert('L').crop(box))
        changed = sum(1 for p in d.get_flattened_data() if p > a.threshold)
        print(f'{f}\tbbox={d.getbbox()}\tchanged={changed}')


if __name__ == '__main__':
    main()
