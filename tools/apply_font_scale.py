import io, re, glob, os

# .font(.system(size: 15, weight: .semibold)) -> .font(.app(15, weight: .semibold))
pat_font = re.compile(r'\.font\(\.system\(([^()]*)\)\)')
# UIFont.systemFont(ofSize: 16) -> UIFont.app(16)
pat_ui = re.compile(r'UIFont\.systemFont\(ofSize:\s*([^(),]+)\)')
# UIFont.boldSystemFont(ofSize: 16) -> UIFont.app(16, weight: .bold)
pat_ui_bold = re.compile(r'UIFont\.boldSystemFont\(ofSize:\s*([^(),]+)\)')


def fix_font(m):
    inner = m.group(1)
    # 去掉 size: 这个参数名，函数签名用的是无标签的第一个参数
    inner = re.sub(r'^\s*size:\s*', '', inner)
    return '.font(.app(' + inner + '))'


total = 0
for path in sorted(glob.glob('Cuiban/*.swift')):
    src = io.open(path, encoding='utf-8').read()
    orig = src
    src, n1 = pat_font.subn(fix_font, src)
    src, n2 = pat_ui.subn(lambda m: 'UIFont.app(' + m.group(1) + ')', src)
    src, n3 = pat_ui_bold.subn(lambda m: 'UIFont.app(' + m.group(1) + ', weight: .bold)', src)
    if src != orig:
        io.open(path, 'w', encoding='utf-8', newline='').write(src)
        total += n1 + n2 + n3
        print(os.path.basename(path), 'font:', n1, 'uifont:', n2, 'uibold:', n3)
print('total:', total)
