#!/usr/bin/env python3
"""y700: let kwin-effect-upscale act on a rotated output (the Y700 panel is portrait, used rotated 90 deg)."""
import os
P = '/usr/local/src/kwin-effect-upscale/src/plugins/upscale'
def edit(name, old, new, marker):
    f = os.path.join(P, name); s = open(f, encoding='utf-8').read()
    if marker in s: print(name, 'already patched'); return
    assert old in s, (name, old[:50]); s = s.replace(old, new, 1)
    open(f, 'w', encoding='utf-8').write(s); print(name, 'patched')
edit('eligibility.cpp',
     '    if (window->screen()->transform() != OutputTransform::Normal) {\n        return UpscaleRefusal::TransformedOutput;\n    }\n',
     '    // y700: a rotated output is drawn through the viewport projection like a flipped one; not refused.\n',
     'y700: a rotated output')
edit('eligibility.cpp',
     '    if (transform != OutputTransform::Normal && transform != OutputTransform::FlipY) {\n        return UpscaleRefusal::TransformedRenderTarget;\n    }\n',
     '    (void)transform; // y700: rotated targets are allowed, the projection matrix carries the rotation\n',
     'y700: rotated targets')
edit('x11resolution.cpp',
     '        || window->isUnmanaged() || !window->isNormalWindow() || !window->output()\n        || window->output()->transform() != OutputTransform::Normal\n',
     '        || window->isUnmanaged() || !window->isNormalWindow() || !window->output() // y700: rotated output allowed\n',
     'y700: rotated output allowed')
edit('waylandinitial.cpp',
     '    if (std::abs(window->output()->scale() - 1.0) > 0.001 || window->output()->transform() != OutputTransform::Normal) {',
     '    if (std::abs(window->output()->scale() - 1.0) > 0.001) { // y700: rotated output allowed',
     'y700: rotated output allowed')

"""y700: tolerate a 1% aspect difference (3040x1904 lists no exact-aspect Xwayland mode; 1680x1050 / 1440x900 are 0.2% off)."""
f = '/usr/local/src/kwin-effect-upscale/src/plugins/upscale/resolution.h'
s = open(f, encoding='utf-8').read()
old = '    return difference <= 0.5 * (double(output.width) + output.height);\n'
new = ('    // y700: the panel is 3040x1904 (not an exact 16:10) and Xwayland lists only standard 16:10 modes,\n'
       '    // so a 1% aspect difference (a few pixels of letterbox under Fit) is accepted as the same shape.\n'
       '    return difference <= std::max(0.5 * (double(output.width) + output.height), 0.01 * double(input.height) * output.width);\n')
if 'y700: the panel' in s: print('already patched')
else:
    assert old in s; s = s.replace(old, new, 1)
    if '#include <algorithm>' not in s: s = s.replace('#include <cmath>', '#include <algorithm>\n#include <cmath>', 1) if '#include <cmath>' in s else s
    open(f, 'w', encoding='utf-8').write(s); print('resolution.h patched')
print('includes:', [l for l in s.splitlines() if l.startswith('#include')])
