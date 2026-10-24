#!/usr/bin/env python3
"""Add Snapdragon GSR 1 as a third filter to JensKSP/kwin-effect-upscale (checkout on the tablet).

Run from the repository root after copying sgsr.frag next to this script:
    python3 add-sgsr.py
Idempotent: each edit is skipped when its marker is already present.
"""
import os, re, shutil, sys

ROOT = os.getcwd()
P = os.path.join(ROOT, 'src', 'plugins', 'upscale')
HERE = os.path.dirname(os.path.abspath(__file__))


def edit(path, pairs, marker):
    full = os.path.join(P, path)
    s = open(full, encoding='utf-8').read()
    if marker in s:
        print(f'{path}: already patched'); return
    for old, new in pairs:
        assert old in s, f'{path}: anchor not found: {old[:60]!r}'
        s = s.replace(old, new, 1)
    open(full, 'w', encoding='utf-8').write(s)
    print(f'{path}: patched')


# 1. the enum (appended: FSR=0, Nearest=1 keep their stored values)
edit('picture.h', [(
    '    Fsr,\n    Nearest,\n};',
    '    Fsr,\n    Nearest,\n    Sgsr, // Snapdragon Game Super Resolution 1 (y700)\n};')], 'Sgsr,')

# 2. settings: name <-> value, filter()
edit('settings.cpp', [
    ('    return value == int(UpscaleFilter::Nearest) ? QStringLiteral("Nearest") : QStringLiteral("FSR");',
     '    if (value == int(UpscaleFilter::Sgsr)) {\n        return QStringLiteral("SGSR");\n    }\n'
     '    return value == int(UpscaleFilter::Nearest) ? QStringLiteral("Nearest") : QStringLiteral("FSR");'),
    ('    if (name == QLatin1String("FSR")) {\n        return int(UpscaleFilter::Fsr);\n    }',
     '    if (name == QLatin1String("FSR")) {\n        return int(UpscaleFilter::Fsr);\n    }\n'
     '    if (name == QLatin1String("SGSR")) {\n        return int(UpscaleFilter::Sgsr);\n    }'),
    ('    {UpscaleSetting::Filter, "Filter", UpscaleSettingType::Choice, 0, 1, globalFilter, filterName, filterValue},',
     '    {UpscaleSetting::Filter, "Filter", UpscaleSettingType::Choice, 0, 2, globalFilter, filterName, filterValue},'),
    ('    return value(UpscaleSetting::Filter) == int(UpscaleFilter::Nearest) ? UpscaleFilter::Nearest : UpscaleFilter::Fsr;',
     '    switch (value(UpscaleSetting::Filter)) {\n    case int(UpscaleFilter::Nearest):\n        return UpscaleFilter::Nearest;\n'
     '    case int(UpscaleFilter::Sgsr):\n        return UpscaleFilter::Sgsr;\n    default:\n        return UpscaleFilter::Fsr;\n    }'),
], 'UpscaleFilter::Sgsr')

# 3. the setting's label
edit('settingtext.cpp', [(
    '        case int(UpscaleFilter::Nearest):\n            return i18nc("Scaling filter", "Nearest neighbor");',
    '        case int(UpscaleFilter::Nearest):\n            return i18nc("Scaling filter", "Nearest neighbor");\n'
    '        case int(UpscaleFilter::Sgsr):\n            return i18nc("Scaling filter", "Snapdragon GSR 1");')], 'UpscaleFilter::Sgsr')

# 4. kcfg range
edit('upscaleconfig.kcfg', [(
    '<entry name="Filter" type="Int"><default>0</default><min>0</min><max>1</max></entry>',
    '<entry name="Filter" type="Int"><default>0</default><min>0</min><max>2</max></entry>')], '<max>2</max></entry>\n        <!-- What the global')

# 5. what the overlay and diagnostics call it
edit('snapshot_headsup.cpp', [(
    '        QString filter = i18n("FSR 1");\n        if (snapshot.filter == UpscaleFilter::Nearest) {',
    '        QString filter = i18n("FSR 1");\n        if (snapshot.filter == UpscaleFilter::Sgsr) {\n            filter = i18n("SGSR 1");\n        }\n'
    '        if (snapshot.filter == UpscaleFilter::Nearest) {')], 'UpscaleFilter::Sgsr')
edit('snapshot.cpp', [(
    '    QString filter = snapshot.filter == UpscaleFilter::Nearest ? i18n("Nearest neighbor")',
    '    QString filter = snapshot.filter == UpscaleFilter::Sgsr ? i18n("Snapdragon GSR 1, sharpening %1%", qRound(snapshot.sharpening * 100))\n'
    '                   : snapshot.filter == UpscaleFilter::Nearest ? i18n("Nearest neighbor")')], 'UpscaleFilter::Sgsr')

# 6. the scaler: a second enlargement shader pair, chosen per drawing
edit('scaler.h', [
    ('    std::unique_ptr<GLShader> m_easuDirect;\n    std::unique_ptr<GLShader> m_rcasDirect;',
     '    std::unique_ptr<GLShader> m_easuDirect;\n    std::unique_ptr<GLShader> m_rcasDirect;\n'
     '    std::unique_ptr<GLShader> m_sgsr; // Snapdragon GSR 1 (y700)\n    std::unique_ptr<GLShader> m_sgsrDirect;'),
], 'm_sgsr;')
s = open(os.path.join(P, 'scaler.h'), encoding='utf-8').read()
m = re.search(r'void scale\(const RenderTarget &target, const RenderViewport &viewport, GLTexture \*input,\n(\s+)const UpscaleRectF &destination, const UpscaleRegion &region, double strength\);', s)
if m and 'UpscaleFilter filter, double strength);' not in s:
    s = s.replace(m.group(0), m.group(0).replace('double strength);', 'UpscaleFilter filter, double strength);'))
    open(os.path.join(P, 'scaler.h'), 'w', encoding='utf-8').write(s); print('scaler.h: scale() signature patched')

edit('scaler.cpp', [
    ('    m_rcasDirect = loadShader(QStringLiteral(":/effects/upscale/shaders/sharpen.frag"), true);',
     '    m_rcasDirect = loadShader(QStringLiteral(":/effects/upscale/shaders/sharpen.frag"), true);\n'
     '    m_sgsr = loadShader(QStringLiteral(":/effects/upscale/shaders/sgsr.frag"));\n'
     '    m_sgsrDirect = loadShader(QStringLiteral(":/effects/upscale/shaders/sgsr.frag"), true);'),
    ('        && validShader(m_easuDirect.get()) && validShader(m_rcasDirect.get());',
     '        && validShader(m_easuDirect.get()) && validShader(m_rcasDirect.get())\n'
     '        && validShader(m_sgsr.get()) && validShader(m_sgsrDirect.get());'),
    ('                          const UpscaleRectF &destination, const UpscaleRegion &region, double strength)\n{\n    const QSize inputSize = input->size();',
     '                          const UpscaleRectF &destination, const UpscaleRegion &region, UpscaleFilter filter, double strength)\n{\n    const QSize inputSize = input->size();'),
    ('    GLShader *easu = direct ? m_easuDirect.get() : m_easu.get();\n    const ShaderBinder binder(easu);',
     '    // Snapdragon GSR 1 takes the same uniforms and the same place in the pipeline as EASU (y700)\n'
     '    GLShader *easu = filter == UpscaleFilter::Sgsr ? (direct ? m_sgsrDirect.get() : m_sgsr.get())\n'
     '                                                  : (direct ? m_easuDirect.get() : m_easu.get());\n    const ShaderBinder binder(easu);'),
    ('    scale(target, viewport, input, destination, region, strength);',
     '    scale(target, viewport, input, destination, region, drawing.filter, strength);'),
], 'm_sgsr = loadShader')

# 7. resources
edit('upscale.qrc', [(
    '        <file>shaders/sharpen.frag</file>',
    '        <file>shaders/sharpen.frag</file>\n        <file>shaders/sgsr.frag</file>')], 'sgsr.frag')
shutil.copy(os.path.join(HERE, 'sgsr.frag'), os.path.join(P, 'shaders', 'sgsr.frag'))
print('shaders/sgsr.frag copied')
