# usage: addfile.py <pbxproj> <new filename> <sibling filename already in project>
# Adds the new file next to the sibling: same group, and to every Sources phase the sibling is in.
import sys, re, hashlib
p, new, sib = sys.argv[1:4]
s = open(p).read()
def hid(*a): return hashlib.md5('|'.join(a).encode()).hexdigest()[:24].upper()
m = re.search(r'\t\t(\w+) /\* %s \*/ = \{isa = PBXFileReference;' % re.escape(sib), s)
sibref = m.group(1)
ref = hid('ref', new)
line = m.group(0)
full = s[m.start():s.index('\n', m.start())]
s = s.replace(full, full + '\n' + full.replace(sibref, ref).replace(sib, new), 1)
# group
s = re.sub(r'(\t+)%s /\* %s \*/,\n' % (sibref, re.escape(sib)),
           lambda g: g.group(0) + f'{g.group(1)}{ref} /* {new} */,\n', s, count=1)
# build files
for bm in list(re.finditer(r'\t\t(\w+) /\* %s in Sources \*/ = \{isa = PBXBuildFile; fileRef = %s [^\n]*' % (re.escape(sib), sibref), s)):
    bf = bm.group(1); nbf = hid('bf', new, bf)
    s = s.replace(bm.group(0), bm.group(0) + '\n' + bm.group(0).replace(bf, nbf).replace(sibref, ref).replace(sib, new), 1)
    s = re.sub(r'(\t+)%s /\* %s in Sources \*/,\n' % (bf, re.escape(sib)),
               lambda g: g.group(0) + f'{g.group(1)}{nbf} /* {new} in Sources */,\n', s, count=1)
open(p, 'w').write(s)
print('added', new, ref)
