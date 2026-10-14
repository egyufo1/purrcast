# Draws Purrcast's mascot, an original ginger cat in the webapp.wtf neo-brutalist style (ink outline, hard shadow):
#   purr.svg       – purring head (app, icon)
#   purr_fire.svg  – fire-breathing version (README cover)
# Run: python3 Resources/Icon/make_mascot.py Resources/Icon
import math, re, sys
out_dir = sys.argv[1]
INK, CORAL, PAPER, LAV, ACID, CREAM, AMBER = '#25221F', '#FF8059', '#F5F0E7', '#BFABEF', '#DFEF68', '#FFFAF0', '#FFB13B'
HEAD = "M30,150 C16,122 20,84 40,64 L34,14 L80,44 C93,40 107,40 120,44 L166,14 L160,64 C180,84 184,122 170,150 C150,172 50,172 30,150 Z"

def head(eyes, mouth):
    return f'''<g transform="translate(7 7)"><path fill="{INK}" d="{HEAD}"/></g>
<path fill="{CORAL}" stroke="{INK}" stroke-width="4" stroke-linejoin="round" d="{HEAD}"/>
<path fill="{PAPER}" stroke="{INK}" stroke-width="3" stroke-linejoin="round" d="M46,58 L43,32 L66,47 Z M154,58 L157,32 L134,47 Z"/>
<path fill="none" stroke="{INK}" stroke-width="4" stroke-linecap="round" d="M88,52 L90,66 M100,49 L100,64 M112,52 L110,66"/>
{eyes}
<ellipse cx="58" cy="122" rx="11" ry="6" fill="{LAV}"/><ellipse cx="142" cy="122" rx="11" ry="6" fill="{LAV}"/>
<path fill="none" stroke="{INK}" stroke-width="2.5" stroke-linecap="round" d="M44,128 L14,122 M46,136 L14,142 M156,128 L186,122 M154,136 L186,142"/>
{mouth}'''

purring_eyes = f'<path fill="none" stroke="{INK}" stroke-width="4.5" stroke-linecap="round" d="M56,102 Q70,90 84,102 M116,102 Q130,90 144,102"/>'
nose = f'<path fill="{INK}" d="M92,114 Q100,111 108,114 Q104,121 100,122 Q96,121 92,114 Z"/>'
smile = nose + f'<path fill="none" stroke="{INK}" stroke-width="3.5" stroke-linecap="round" d="M100,122 C100,131 90,133 86,126 M100,122 C100,131 110,133 114,126"/>'

open(f'{out_dir}/purr.svg', 'w').write(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="8 8 186 168">' + head(purring_eyes, smile) + '</svg>')

# Fire version: squeezed "> <" eyes, open mouth, flame to the left.
squeezed = f'<path fill="none" stroke="{INK}" stroke-width="4.5" stroke-linecap="round" stroke-linejoin="round" d="M60,92 L82,102 L60,112 M140,92 L118,102 L140,112"/>'
open_mouth = nose + f'<path fill="{INK}" d="M89,127 Q100,121 111,127 Q112,142 100,143 Q88,142 89,127 Z"/><path fill="{CORAL}" d="M93,137 Q100,132 107,137 Q105,142 100,142 Q95,142 93,137 Z"/>'

FLAME = ("M0,-5 C-18,-13 -42,-27 -76,-33 C-100,-37 -126,-48 -150,-68 C-142,-52 -130,-40 -112,-30 "
         "C-136,-31 -160,-27 -184,-15 C-166,-6 -148,1 -128,5 C-146,13 -158,24 -166,38 "
         "C-142,30 -118,32 -96,31 C-62,29 -26,16 0,5 Z")
def place(d, f, ox, oy, deg, dy=0):
    a = math.radians(deg); c, s = math.cos(a), math.sin(a)
    def tr(m):
        x, y = float(m.group(1)) * f, (float(m.group(2)) + dy) * f
        return '%.2f,%.2f' % (ox + x * c - y * s, oy + x * s + y * c)
    return re.sub(r'(-?[\d.]+),(-?[\d.]+)', tr, d)
MX, MY, ROT = 94, 136, -22
flame = ''
outer = place(FLAME, 1.0, MX, MY, ROT)
flame += f'<path fill="{INK}" transform="translate(6 6)" d="{outer}"/>'
flame += f'<path fill="{AMBER}" stroke="{INK}" stroke-width="3.5" stroke-linejoin="round" d="{outer}"/>'
flame += f'<path fill="{ACID}" stroke="{INK}" stroke-width="2.5" stroke-linejoin="round" d="{place(FLAME, 0.66, MX - 4, MY, ROT, 1)}"/>'
flame += f'<path fill="{CREAM}" d="{place(FLAME, 0.36, MX - 6, MY, ROT, 1.5)}"/>'
def spark(x, y, s, col):
    return (f'<path fill="{col}" stroke="{INK}" stroke-width="2" stroke-linejoin="round" '
            f'd="M{x},{y - s * 1.7} L{x + s},{y} L{x},{y + s * 1.7} L{x - s},{y} Z"/>')
sparks = ''.join(spark(*a) for a in [(-30, 120, 5.5, ACID), (-4, 104, 3.5, AMBER), (-112, 150, 4.5, AMBER),
                                      (-104, 214, 5, ACID), (-78, 244, 3.5, AMBER), (8, 232, 3.5, ACID)])
pts = [tuple(map(float, m)) for m in re.findall(r'(-?[\d.]+),(-?[\d.]+)', outer)]
x0 = min(min(x for x, _ in pts) - 10, -112 - 8); y1 = max(max(y for _, y in pts) + 12, 256)
VB = '%g 8 %g %g' % (x0, 196 - x0, y1 - 8)
open(f'{out_dir}/purr_fire.svg', 'w').write(
    f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{VB}">' + sparks + head(squeezed, open_mouth) + flame + '</svg>')
