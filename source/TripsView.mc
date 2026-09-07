import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Lang;
import Tinymetrix;

// -- Trips loading progress bar delegate --
// Calls fetchTrips and builds the menu when data arrives.

class TripsLoadingDelegate extends WatchUi.BehaviorDelegate {
    function initialize() {
        BehaviorDelegate.initialize();
        getApp().biciMadService.fetchTrips(method(:onTripsReceived));
    }

    function onTripsReceived(success as Boolean, trips as Array?) as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN); // close ProgressBar

        if (!success || trips == null) {
            WatchUi.pushView(
                new WatchUi.Confirmation((WatchUi.loadResource(Rez.Strings.NetworkErrorRetry) as String)),
                new TripsRetryDelegate(),
                WatchUi.SLIDE_UP
            );
            return;
        }

        var activeTrip = null as Dictionary?;
        var completed  = [] as Array;

        for (var i = 0; i < trips.size(); i++) {
            var t = trips[i] as Dictionary;
            var isActive = t.get("active") as Boolean?;
            if (isActive != null && isActive && activeTrip == null) {
                activeTrip = t;
            } else if ((isActive == null || !isActive) && completed.size() < 5) {
                completed.add(t);
            }
        }

        WatchUi.pushView(
            new TripsMenu(activeTrip, completed),
            new TripsMenuDelegate(activeTrip, completed),
            WatchUi.SLIDE_UP
        );
    }

    function onBack() as Boolean { WatchUi.popView(WatchUi.SLIDE_DOWN); return true; }
}

class TripsRetryDelegate extends WatchUi.ConfirmationDelegate {
    function initialize() { ConfirmationDelegate.initialize(); }
    function onResponse(response) as Boolean {
        if (response == WatchUi.CONFIRM_YES) {
            WatchUi.pushView(
                new WatchUi.ProgressBar((WatchUi.loadResource(Rez.Strings.LoadingTrips) as String), null),
                new TripsLoadingDelegate(),
                WatchUi.SLIDE_UP
            );
        }
        return true;
    }
}

// -- Trips menu (built dynamically after loading data) --

class TripsMenu extends WatchUi.Menu2 {
    function initialize(activeTrip as Dictionary?, completed as Array) {
        Menu2.initialize({:title => (WatchUi.loadResource(Rez.Strings.TripsTitle) as String)});

        // Active trip (only if exists)
        if (activeTrip != null) {
            var undock = activeTrip.get("undock") as Dictionary?;
            var stName = "";
            var startTime = "";
            if (undock != null) {
                var n  = undock.get("name") as String?;
                var ts = undock.get("ts")   as String?;
                if (n  != null) { stName = n.length() > 22 ? n.substring(0, 20) + "..." : n; }
                if (ts != null && ts.length() >= 16) { startTime = ts.substring(11, 16); }
            }
            var idBike = activeTrip.get("bike") as String?;
            var bikeStr = idBike != null ? " · Bike #" + idBike : "";
            addItem(new WatchUi.MenuItem(
                (WatchUi.loadResource(Rez.Strings.TripActive) as String) + bikeStr,
                (WatchUi.loadResource(Rez.Strings.TripFrom) as String) + " " + startTime + "  " + stName,
                :active,
                {}
            ));
        }

        // History
        if (completed.size() == 0) {
            addItem(new WatchUi.MenuItem((WatchUi.loadResource(Rez.Strings.TripHistory) as String), (WatchUi.loadResource(Rez.Strings.NoTrips) as String), :history_empty, {}));
        } else {
            for (var i = 0; i < completed.size(); i++) {
                var t      = completed[i] as Dictionary;
                var mins   = t.get("mins") as Number?;
                var cost   = t.get("cost")    as Number?;
                var undock = t.get("undock") as Dictionary?;

                // Label: date + departure station (without "N - " prefix)
                var date  = "–";
                var stName = "";
                if (undock != null) {
                    var ts = undock.get("ts") as String?;
                    var n  = undock.get("name") as String?;
                    if (ts != null && ts.length() >= 10) { date = ts.substring(0, 10); }
                    if (n  != null) {
                        // Strip "N - " prefix
                        var dash = n.find(" - ");
                        stName = (dash != null && dash >= 0) ? n.substring(dash + 3, n.length()) : n;
                        if (stName.length() > 18) { stName = stName.substring(0, 16) + ".."; }
                    }
                }
                var label = date + (stName.length() > 0 ? "  " + stName : "");

                // SubLabel: cost + duration
                var costStr = cost != null ? cost.format("%.2f") + " €" : "–";
                var minsStr = mins != null ? mins.format("%.0f") + " min" : "";
                var sub = costStr + (minsStr.length() > 0 ? " · " + minsStr : "");

                addItem(new WatchUi.MenuItem(label, sub, i, {}));
            }
        }
    }
}

class TripsMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var _active    as Dictionary?;
    private var _completed as Array;

    function initialize(active as Dictionary?, completed as Array) {
        Menu2InputDelegate.initialize();
        _active    = active;
        _completed = completed;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :active && _active != null) {
            // Open active trip detail screen
            Tinymetrix.Client.track("view_active_trip");
            WatchUi.pushView(new ActiveTripView(_active), new ActiveTripDelegate(), WatchUi.SLIDE_UP);
        }
        // History: informational only, no action
    }

    function onBack() as Void { WatchUi.popView(WatchUi.SLIDE_DOWN); }
}

// -- Active trip detail --

class ActiveTripView extends WatchUi.View {
    private var _trip as Dictionary;

    function initialize(trip as Dictionary) {
        View.initialize();
        _trip = trip;
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(0x121212, Graphics.COLOR_BLACK);
        dc.clear();
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;

        var subH   = dc.getFontHeight(Graphics.FONT_XTINY);
        var gap    = 10;

        dc.setColor(0x00FF66, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.06, Graphics.FONT_MEDIUM, (WatchUi.loadResource(Rez.Strings.ActiveTripTitle) as String), Graphics.TEXT_JUSTIFY_CENTER);

        var idBike = _trip.get("bike") as String?;
        var undock = _trip.get("undock") as Dictionary?;

        var undockName = "–";
        var undockTs   = "–";

        if (undock != null) {
            var n  = undock.get("name") as String?;
            var ts = undock.get("ts") as String?;
            if (n  != null) { undockName = n; }
            if (ts != null && ts.length() >= 16) { undockTs = ts.substring(11, 16); }
        }

        var rows = [
            [(WatchUi.loadResource(Rez.Strings.TripBike) as String),    idBike != null ? "#" + idBike : "–"],
            [(WatchUi.loadResource(Rez.Strings.TripFrom) as String),   undockTs],
            [(WatchUi.loadResource(Rez.Strings.TripStation) as String), undockName.length() > 20 ? undockName.substring(0, 18) + "..." : undockName]
        ] as Array;

        var startY = (h * 0.30).toNumber();

        for (var i = 0; i < rows.size(); i++) {
            var row = rows[i] as Array;
            var y   = startY + i * (subH + gap);
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx - 8, y, Graphics.FONT_XTINY, row[0] as String, Graphics.TEXT_JUSTIFY_RIGHT);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx + 4, y, Graphics.FONT_XTINY, row[1] as String, Graphics.TEXT_JUSTIFY_LEFT);
        }
    }
}

class ActiveTripDelegate extends WatchUi.BehaviorDelegate {
    function initialize() { BehaviorDelegate.initialize(); }
    function onBack() as Boolean { WatchUi.popView(WatchUi.SLIDE_DOWN); return true; }
}
