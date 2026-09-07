import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;
import Tinymetrix;

// -- Unlock bike — Native menu with two options: Plate + Reserve --

class PlateInputMenu extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({:title => (WatchUi.loadResource(Rez.Strings.PlateMenuTitle) as String)});
        addItem(new WatchUi.MenuItem((WatchUi.loadResource(Rez.Strings.PlateLabel) as String),    (WatchUi.loadResource(Rez.Strings.LoginTapToTypeNum) as String), :plate,   {}));
        addItem(new WatchUi.MenuItem((WatchUi.loadResource(Rez.Strings.PlateReserve) as String), null,                    :reserve, {}));
    }
}

class PlateInputDelegate extends WatchUi.Menu2InputDelegate {
    private var _plate     as String             = "";
    private var _plateItem as WatchUi.MenuItem? = null;

    function initialize() { Menu2InputDelegate.initialize(); }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();

        if (id == :plate) {
            _plateItem = item;
            WatchUi.pushView(
                new WatchUi.TextPicker(_plate),
                new PlatePickerDelegate(self),
                WatchUi.SLIDE_UP
            );

        } else if (id == :reserve) {
            if (_plate.length() == 0) {
                item.setSubLabel((WatchUi.loadResource(Rez.Strings.PlateMissingPlate) as String));
                WatchUi.requestUpdate();
                return;
            }
            if (!getApp().isLoggedIn()) {
                item.setSubLabel((WatchUi.loadResource(Rez.Strings.LoginRequired) as String));
                WatchUi.requestUpdate();
                return;
            }

            // Native ProgressBar while verifying the bike
            item.setSubLabel((WatchUi.loadResource(Rez.Strings.Verifying) as String));
            WatchUi.requestUpdate();
            WatchUi.pushView(
                new WatchUi.ProgressBar((WatchUi.loadResource(Rez.Strings.Verifying) as String) + " #" + _plate, null),
                new PlateCheckProgressDelegate(_plate, self),
                WatchUi.SLIDE_UP
            );
        }
    }

    function setPlate(text as String) as Void {
        _plate = text;
        if (_plateItem != null) {
            _plateItem.setSubLabel(text);
            WatchUi.requestUpdate();
        }
    }

    // Called by PlateCheckProgressDelegate when verification is done
    function onPlateChecked(success as Boolean, bikeData as Dictionary?) as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN); // close ProgressBar

        if (success && bikeData != null) {
            var docker = bikeData.get("docker");
            var dockerStr = docker != null ? docker.toString() : "–";
            var lat  = bikeData.get("lat")  as Numeric?;
            var lon  = bikeData.get("lon")  as Numeric?;
            var dist = 0;
            if (lat != null && lon != null) {
                dist = getApp().biciMadService.distanceFromUser(lat.toDouble(), lon.toDouble());
            }
            var distText = dist >= 1000
                ? (dist / 1000.0).format("%.1f") + " km"
                : dist.toString() + " m";
            var fleet = bikeData.get("fleet") as Number?;
            var typeStr = (fleet != null && fleet == 2) ? "BiciMAD Go" : "BiciMAD";
            var msg = typeStr + " #" + _plate +
                      "\nDock: " + dockerStr +
                      "\n" + distText + "\n" + (WatchUi.loadResource(Rez.Strings.Confirm) as String) + "?";
            WatchUi.pushView(
                new WatchUi.Confirmation(msg),
                new PlateConfirmationDelegate(_plate),
                WatchUi.SLIDE_UP
            );
        } else {
            WatchUi.pushView(
                new PlateResultView(false, _plate, (WatchUi.loadResource(Rez.Strings.BikeNotAvailable) as String)),
                new PlateResultDelegate(),
                WatchUi.SLIDE_UP
            );
        }
    }

    function onBack() as Void { WatchUi.popView(WatchUi.SLIDE_DOWN); }
}

class PlatePickerDelegate extends WatchUi.TextPickerDelegate {
    private var _parent as PlateInputDelegate;
    function initialize(p as PlateInputDelegate) { TextPickerDelegate.initialize(); _parent = p; }
    function onTextEntered(text as String, changed as Boolean) as Boolean {
        if (text.length() > 0) { _parent.setPlate(text); }
        return true;
    }
    function onCancel() as Boolean { return true; }
}

// -- Verification progress bar delegate --
// Runs checkBikeByPlate and notifies the parent when done.

class PlateCheckProgressDelegate extends WatchUi.BehaviorDelegate {
    private var _plate  as String;
    private var _parent as PlateInputDelegate;

    function initialize(plate as String, parent as PlateInputDelegate) {
        BehaviorDelegate.initialize();
        _plate  = plate;
        _parent = parent;
        // Start verification as soon as the progress bar is shown
        getApp().biciMadService.checkBikeByPlate(_plate, method(:onDone));
    }

    function onDone(success as Boolean, bikeData as Dictionary?) as Void {
        _parent.onPlateChecked(success, bikeData);
    }

    function onCancel() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        return true;
    }
}

// -- Confirmation delegate (native WatchUi.Confirmation) --

class PlateConfirmationDelegate extends WatchUi.ConfirmationDelegate {
    private var _plate as String;
    function initialize(plate as String) { ConfirmationDelegate.initialize(); _plate = plate; }
    function onResponse(response) as Boolean {
        if (response == WatchUi.CONFIRM_YES) {
            WatchUi.pushView(
                new WatchUi.ProgressBar((WatchUi.loadResource(Rez.Strings.Unlocking) as String) + " #" + _plate, null),
                new PlateUnlockProgressDelegate(_plate),
                WatchUi.SLIDE_UP
            );
        }
        return true;
    }
}

// -- Unlock progress bar delegate --
// Runs unlockBike and shows the result.

class PlateUnlockProgressDelegate extends WatchUi.BehaviorDelegate {
    private var _plate as String;

    function initialize(plate as String) {
        BehaviorDelegate.initialize();
        _plate = plate;
        Tinymetrix.Client.track("unlock_bike");
        getApp().biciMadService.unlockBike(_plate, method(:onDone));
    }

    function onDone(success as Boolean, description as String?) as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN); // close ProgressBar
        WatchUi.pushView(
            new PlateResultView(success, _plate, description),
            new PlateResultDelegate(),
            WatchUi.SLIDE_UP
        );
    }

    function onCancel() as Boolean {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        return true;
    }
}

// -- Result screen (success or error) --

class PlateResultView extends WatchUi.View {
    private var _success as Boolean;
    private var _plate   as String;
    private var _desc    as String;

    function initialize(success as Boolean, plate as String, desc as String?) {
        View.initialize();
        _success = success;
        _plate   = plate;
        _desc    = desc != null ? desc : "";
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(0x121212, Graphics.COLOR_BLACK);
        dc.clear();
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;

        var medH   = dc.getFontHeight(Graphics.FONT_MEDIUM);
        var xtinyH = dc.getFontHeight(Graphics.FONT_XTINY);
        var gap    = 10;

        // Vertically centered block
        var lines = _desc.length() > 0 ? 3 : 2;
        var blockH = medH + gap + xtinyH + (lines > 2 ? gap + xtinyH : 0);
        var ty = (h - blockH) / 2;

        if (_success) {
            dc.setColor(0x00FF66, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, ty, Graphics.FONT_MEDIUM, (WatchUi.loadResource(Rez.Strings.BikeUnlocked) as String), Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, ty + medH + gap, Graphics.FONT_XTINY, "Bike #" + _plate, Graphics.TEXT_JUSTIFY_CENTER);
            if (_desc.length() > 0) {
                dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, ty + medH + gap + xtinyH + gap, Graphics.FONT_XTINY, _desc, Graphics.TEXT_JUSTIFY_CENTER);
            }
        } else {
            dc.setColor(0xFF4444, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, ty, Graphics.FONT_MEDIUM, (WatchUi.loadResource(Rez.Strings.BikeNotAvailable) as String), Graphics.TEXT_JUSTIFY_CENTER);
            if (_plate.length() > 0) {
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, ty + medH + gap, Graphics.FONT_XTINY, "Bike #" + _plate, Graphics.TEXT_JUSTIFY_CENTER);
            }
            if (_desc.length() > 0) {
                var shortDesc = _desc.length() > 30 ? _desc.substring(0, 28) + ".." : _desc;
                dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, ty + medH + gap + xtinyH + gap, Graphics.FONT_XTINY, shortDesc, Graphics.TEXT_JUSTIFY_CENTER);
            }
        }

        dc.setColor(0x333333, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h - dc.getFontHeight(Graphics.FONT_XTINY) - 8,
            Graphics.FONT_XTINY, (WatchUi.loadResource(Rez.Strings.SelectToGoBack) as String), Graphics.TEXT_JUSTIFY_CENTER);
    }
}

class PlateResultDelegate extends WatchUi.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }
    function onSelect() as Boolean { WatchUi.popView(WatchUi.SLIDE_DOWN); return true; }
    function onTap(evt as WatchUi.ClickEvent) as Boolean { return onSelect(); }
    function onBack()   as Boolean { WatchUi.popView(WatchUi.SLIDE_DOWN); return true; }
}
