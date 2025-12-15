import sys
import json
import plistlib

json_file = sys.argv[1]
plist_file = sys.argv[2]

with open(json_file, 'r') as jf:
    config = json.load(jf)

with open(plist_file, 'rb') as pf:
    plist = plistlib.load(pf)

plist.update(config)

with open(plist_file, 'wb') as pf:
    plistlib.dump(plist, pf)

print("Info.plist updated successfully.")
