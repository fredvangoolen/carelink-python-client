# Runs carelink_carepartner_api_login.py unmodified, on a board where
# Selenium cannot find its own binaries.
#
# Selenium Manager has no linux/aarch64 build - it raises "Unsupported
# platform/architecture combination" before it ever looks at PATH - and the
# login script calls webdriver.Firefox() with no arguments, so there is no
# seam to pass paths through. Patching the attribute on the module it
# imported is enough, and leaves the project file byte-identical to upstream.
#
# Pre-installing geckodriver rather than letting Selenium fetch one is also
# the right call for an appliance: no download at the moment someone is
# standing there waiting to log in.
import os
import sys

DISPLAY = os.environ.get("DISPLAY", ":1")
FIREFOX = os.environ.get("FIREFOX_BIN", "/usr/bin/firefox-esr")
GECKODRIVER = os.environ.get("GECKODRIVER_BIN", "/usr/local/bin/geckodriver")
LOGIN_DIR = os.environ.get("LOGIN_DIR", "/opt/carelink-renewal")
WIDTH = os.environ.get("SCREEN_WIDTH", "1280")
HEIGHT = os.environ.get("SCREEN_HEIGHT", "800")

os.environ["DISPLAY"] = DISPLAY
sys.path.insert(0, LOGIN_DIR)

from seleniumwire import webdriver as _wdw                      # noqa: E402
from selenium.webdriver.firefox.service import Service          # noqa: E402

_orig_firefox = _wdw.Firefox


def _firefox(*args, **kwargs):
    opts = kwargs.get("options") or _wdw.FirefoxOptions()
    opts.binary_location = FIREFOX
    # Fill the virtual display, so whoever is looking over noVNC gets the
    # whole login form rather than a small window in a grey field.
    opts.add_argument("--width=%s" % WIDTH)
    opts.add_argument("--height=%s" % HEIGHT)
    kwargs["options"] = opts
    kwargs.setdefault("service", Service(executable_path=GECKODRIVER))
    return _orig_firefox(*args, **kwargs)


_wdw.Firefox = _firefox

# Importing runs it: the script does its work at module level.
import carelink_carepartner_api_login   # noqa: E402,F401
