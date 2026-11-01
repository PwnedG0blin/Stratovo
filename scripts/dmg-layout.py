"""Finder layout written on the mounted image, without GUI automation."""
from pathlib import Path
import sys
from ds_store import DSStore
from mac_alias import Alias
root = Path(sys.argv[1]).resolve()
with DSStore.open(str(root / '.DS_Store'), 'w+') as store:
    store['.']['vSrn'] = ('long', 1)
    store['.']['vstl'] = ('type', b'icnv')
    store['.']['bwsp'] = {'ShowToolbar': False, 'ShowStatusBar': False,
        'ShowSidebar': False, 'ShowPathbar': False,
        'WindowBounds': '{{180, 110}, {1000, 620}}'}
    store['.']['icvp'] = {'viewOptionsVersion': 1, 'backgroundType': 2,
        'backgroundImageAlias': Alias.for_file(str(root / '.background/background.png')).to_bytes(),
        'iconSize': 112.0, 'textSize': 13.0, 'gridSpacing': 100.0,
        'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'arrangeBy': 'none',
        'labelOnBottom': True, 'showIconPreview': True, 'showItemInfo': False}
    for name, position in {'Stratovo.app': (230, 340), 'Applications': (770, 340),
                           'Bitte_zuerst_lesen.txt': (420, 530), 'LICENSE': (580, 530)}.items():
        store[name]['Iloc'] = position
