"""Write the shared light drag-to-Applications Finder layout."""
from pathlib import Path
import sys
from ds_store import DSStore
from mac_alias import Alias

root = Path(sys.argv[1]).resolve()
with DSStore.open(str(root / '.DS_Store'), 'w+') as store:
    store['.']['vSrn'] = ('long', 1)
    store['.']['vstl'] = ('type', b'icnv')
    store['.']['bwsp'] = {
        'ShowToolbar': False, 'ShowStatusBar': False, 'ShowSidebar': False,
        'ShowPathbar': False, 'WindowBounds': '{{180, 110}, {540, 320}}'
    }
    store['.']['icvp'] = {
        'viewOptionsVersion': 1, 'backgroundType': 2,
        'backgroundImageAlias': Alias.for_file(str(root / '.background/background.png')).to_bytes(),
        'iconSize': 64.0, 'textSize': 12.0, 'gridSpacing': 100.0,
        'gridOffsetX': 0.0, 'gridOffsetY': 0.0, 'arrangeBy': 'none',
        'labelOnBottom': True, 'showIconPreview': True, 'showItemInfo': False
    }
    for name, position in {'Stratovo.app': (130, 210), 'Applications': (410, 210)}.items():
        store[name]['Iloc'] = position
