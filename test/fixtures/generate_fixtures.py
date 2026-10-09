# Generates the PDF fixtures in this folder (run from a scratch venv):
#   python3 -m venv venv && venv/bin/pip install pikepdf pypdf cryptography reportlab
#   venv/bin/python generate_fixtures.py <out-dir>
# then copy <out-dir>/*.pdf here. Part 1 uses pikepdf (qpdf): a hand-made
# form with every field kind, hierarchy, rotated/cropped pages, plus
# object-stream, linearized and encrypted (RC4 40/128, AES-128, AES-256 R5/R6,
# owner-only) variants. Part 2 uses ReportLab + pypdf.
import pikepdf, sys, os
from pikepdf import Pdf, Dictionary, Array, Name, String, Stream, Encryption, Permissions

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

def ap_stream(pdf, w, h, content=b''):
    return pdf.make_stream(content, Type=Name.XObject, Subtype=Name.Form, BBox=[0, 0, w, h])

def build():
    pdf = Pdf.new()
    helv = pdf.make_indirect(Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.Helvetica, Encoding=Name.WinAnsiEncoding))
    zadb = pdf.make_indirect(Dictionary(Type=Name.Font, Subtype=Name.Type1, BaseFont=Name.ZapfDingbats))
    pages = []
    for i, (mb, rot, crop) in enumerate([([0,0,612,792], 0, None), ([0,0,612,792], 90, None), ([0,0,600,800], 0, [50,100,550,700])]):
        content = pdf.make_stream(b'BT /F1 18 Tf 72 740 Td (Page %d) Tj ET' % (i+1))
        p = Dictionary(Type=Name.Page, MediaBox=mb, Contents=content,
                       Resources=Dictionary(Font=Dictionary(F1=helv)))
        if rot: p.Rotate = rot
        if crop: p.CropBox = crop
        pdf.pages.append(pikepdf.Page(p))
    pg = [pdf.pages[i].obj for i in range(3)]
    fields = Array()
    annots = [Array(), Array(), Array()]
    def widget(page, rect, **kw):
        d = Dictionary(Type=Name.Annot, Subtype=Name.Widget, Rect=rect, F=4, P=pg[page], **kw)
        return d
    def add(page, d, top=True):
        d = pdf.make_indirect(d)
        annots[page].append(d)
        if top: fields.append(d)
        return d
    # 1 simple text field, merged
    w = widget(0, [72, 680, 272, 700], FT=Name.Tx, T=String('name'), V=String('Alice'), DA=String('/Helv 10 Tf 0 g'),
               MK=Dictionary(BC=[0,0,0], BG=[1,1,0.8]))
    w.AP = Dictionary(N=ap_stream(pdf, 200, 20, b'/Tx BMC EMC'))
    add(0, w)
    # 2 multiline, Q=1, required
    add(0, widget(0, [72, 560, 372, 660], FT=Name.Tx, Ff=4096|2, Q=1, T=String('notes'), V=String('Line one\nLine two'), DA=String('/Helv 0 Tf 0 0 1 rg')))
    # 3 parent with two kids widgets (same field shown twice)
    parent = pdf.make_indirect(Dictionary(FT=Name.Tx, T=String('dup'), V=String('same'), DA=String('/Helv 9 Tf 0 g'), Kids=Array()))
    for r in ([72, 520, 222, 540], [252, 520, 402, 540]):
        k = pdf.make_indirect(widget(0, r, Parent=parent))
        parent.Kids.append(k)
        annots[0].append(k)
    fields.append(parent)
    # 4 hierarchy: person.first, person.age (inherit FT/DA from parent)
    person = pdf.make_indirect(Dictionary(T=String('person'), FT=Name.Tx, DA=String('/Helv 11 Tf 0 g'), Kids=Array()))
    for nm, r, extra in (('first', [72, 480, 222, 500], {}), ('age', [252, 480, 302, 500], dict(MaxLen=3, Ff=1<<24))):
        k = pdf.make_indirect(widget(0, r, T=String(nm), Parent=person, **extra))
        person.Kids.append(k); annots[0].append(k)
    fields.append(person)
    # 5 checkbox
    on = ap_stream(pdf, 14, 14, b'q BT /ZaDb 10 Tf 2 3 Td (4) Tj ET Q'); on.Resources = Dictionary(Font=Dictionary(ZaDb=zadb))
    off = ap_stream(pdf, 14, 14)
    add(0, widget(0, [72, 440, 86, 454], FT=Name.Btn, T=String('agree'), V=Name.Off, AS=Name.Off,
                  AP=Dictionary(N=Dictionary(Yes=on, Off=off)), MK=Dictionary(CA=String('4'))))
    # 6 radio group with three kids
    radio = pdf.make_indirect(Dictionary(FT=Name.Btn, Ff=(1<<15)|(1<<14), T=String('color'), V=Name('/green'), Kids=Array()))
    for i, val in enumerate(['red', 'green', 'blue']):
        onr = ap_stream(pdf, 14, 14, b'q 0 g 7 7 m 7 7 4 4 re f Q'); offr = ap_stream(pdf, 14, 14)
        k = pdf.make_indirect(widget(0, [72 + i*30, 400, 86 + i*30, 414], Parent=radio,
              AS=Name('/' + val) if val == 'green' else Name.Off,
              AP=Dictionary(N=Dictionary({'/' + val: onr, '/Off': offr}))))
        radio.Kids.append(k); annots[0].append(k)
    fields.append(radio)
    # 7 combo
    add(0, widget(0, [72, 360, 222, 380], FT=Name.Ch, Ff=1<<17, T=String('state'), V=String('CA'),
                  Opt=Array([Array([String('CA'), String('California')]), Array([String('NY'), String('New York')])]), DA=String('/Helv 10 Tf 0 g')))
    # 8 list box
    add(0, widget(0, [252, 320, 372, 380], FT=Name.Ch, T=String('fruit'), V=String('Pear'),
                  Opt=Array([String('Apple'), String('Pear'), String('Plum')]), DA=String('/Helv 10 Tf 0 g')))
    # 9 signature, 10 pushbutton, 11 read-only
    add(0, widget(0, [72, 280, 222, 310], FT=Name.Sig, T=String('sig')))
    add(0, widget(0, [252, 280, 322, 300], FT=Name.Btn, Ff=1<<16, T=String('reset')))
    add(0, widget(0, [72, 240, 222, 260], FT=Name.Tx, Ff=1, T=String('fixed'), V=String('locked')))
    # unicode name/value
    add(0, widget(0, [252, 240, 452, 260], FT=Name.Tx, T=String('uni'), V=String('Grüße €')))
    # page 2 (rotated 90) text field
    add(1, widget(1, [100, 100, 300, 130], FT=Name.Tx, T=String('rotated'), V=String('sideways'), DA=String('/Helv 12 Tf 0 g'), MK=Dictionary(R=90)))
    # page 3 (cropbox) field
    add(2, widget(2, [100, 600, 200, 620], FT=Name.Tx, T=String('cropped'), DA=String('/Helv 12 Tf 0 g')))
    for i in range(3):
        pg[i].Annots = annots[i]
    pdf.Root.AcroForm = pdf.make_indirect(Dictionary(Fields=fields, DA=String('/Helv 0 Tf 0 g'),
                       DR=Dictionary(Font=Dictionary(Helv=helv, ZaDb=zadb))))
    pdf.docinfo['/Title'] = 'Test form'
    return pdf

pdf = build()
pdf.save(f'{out}/form.pdf', object_stream_mode=pikepdf.ObjectStreamMode.disable, static_id=False)
pdf = build()
pdf.save(f'{out}/form_objstm.pdf', object_stream_mode=pikepdf.ObjectStreamMode.generate)
pdf = Pdf.open(f'{out}/form.pdf')
pdf.save(f'{out}/form_linearized.pdf', linearize=True)
restricted = Permissions(modify_other=False, modify_annotation=False, modify_form=False, extract=False, print_lowres=True, print_highres=True, modify_assembly=False, accessibility=True)
encs = {
  'rc4_40': dict(R=2, aes=False, metadata=False),
  'rc4_128': dict(R=3, aes=False, metadata=False),
  'aes128': dict(R=4, aes=True),
  'aes256': dict(R=6, aes=True),
}
for name, kw in encs.items():
    pdf = Pdf.open(f'{out}/form.pdf')
    pdf.save(f'{out}/form_{name}.pdf', encryption=Encryption(owner='owner', user='user', **kw))
for name, kw in (('rc4_128', dict(R=3, aes=False, metadata=False)), ('aes128', dict(R=4, aes=True)), ('aes256', dict(R=6, aes=True))):
    pdf = Pdf.open(f'{out}/form.pdf')
    pdf.save(f'{out}/form_{name}_owneronly.pdf', encryption=Encryption(owner='owner', user='', allow=restricted, **kw))
pdf = Pdf.open(f'{out}/form.pdf')
pdf.save(f'{out}/form_aes128_objstm_nometa.pdf', object_stream_mode=pikepdf.ObjectStreamMode.generate,
         encryption=Encryption(owner='owner', user='user', R=4, aes=True, metadata=False))
try:
    pdf = Pdf.open(f'{out}/form.pdf')
    pdf.save(f'{out}/form_aes256_r5.pdf', encryption=Encryption(owner='owner', user='user', R=5, aes=True))
except Exception as e:
    print('R5 failed', e)
print('done')

# ---- second part (ReportLab + pypdf) ----
# Extra fixtures from other producers: ReportLab (AcroForm) and pypdf (AES-256).
import sys, os
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import letter
out = sys.argv[1]
c = canvas.Canvas(f'{out}/reportlab_form.pdf', pagesize=letter)
c.drawString(72, 750, 'ReportLab form')
f = c.acroForm
f.textfield(name='rl_text', value='hello', x=72, y=700, width=200, height=20)
f.textfield(name='rl_multi', value='a\nb', x=72, y=600, width=200, height=80, fieldFlags='multiline')
f.checkbox(name='rl_check', x=72, y=560, size=16, checked=True)
for i, v in enumerate(['one', 'two', 'three']):
    f.radio(name='rl_radio', value=v, selected=(v == 'two'), x=72 + 30 * i, y=520, size=16)
f.choice(name='rl_choice', value='B', options=['A', 'B', 'C'], x=72, y=480, width=100, height=20)
f.listbox(name='rl_list', value='Z', options=['X', 'Y', 'Z'], x=200, y=440, width=100, height=60)
c.showPage()
c.save()
from pypdf import PdfReader, PdfWriter
r = PdfReader(f'{out}/reportlab_form.pdf')
w = PdfWriter(clone_from=r)
w.encrypt(user_password='user', owner_password='owner', algorithm='AES-256')
with open(f'{out}/pypdf_aes256.pdf', 'wb') as fh:
    w.write(fh)
w = PdfWriter(clone_from=r)
w.encrypt(user_password='user', owner_password='owner', algorithm='RC4-128')
with open(f'{out}/pypdf_rc4_128.pdf', 'wb') as fh:
    w.write(fh)
print('ok')
