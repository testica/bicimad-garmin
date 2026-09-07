import Toybox.Position;
import Toybox.Lang;

class PositionManager {
    private var _lastPosition as Position.Location? = null;
    private var _hasLock as Boolean = false;
    private var _callback as (Method(pos as Position.Location) as Void)? = null;

    function initialize() {
        _lastPosition = null;
        _hasLock = false;
    }

    // Start listening to continuous GPS events
    function startGPS(callback as Method(pos as Position.Location) as Void) as Void {
        _callback = callback;
        try {
            Position.enableLocationEvents(Position.LOCATION_CONTINUOUS, method(:onPosition));
        } catch (ex) {
        }
    }

    // Stop listening to save battery
    function stopGPS() as Void {
        try {
            Position.enableLocationEvents(Position.LOCATION_DISABLE, method(:onPosition));
            _callback = null;
        } catch (ex) {
        }
    }

    // Callback invoked by Connect IQ when position updates
    function onPosition(info as Position.Info) as Void {
        var position = info.position;
        if (position != null) {
            var coords = position.toDegrees();
            // Verify if lock is valid (non-zero placeholder check)
            if (coords[0] != 0.0 || coords[1] != 0.0) {
                _lastPosition = position;
                _hasLock = true;

                if (_callback != null) {
                    _callback.invoke(position);
                }
            }
        }
    }

    function hasLock() as Boolean {
        return _hasLock;
    }

    function getLastPosition() as Position.Location? {
        return _lastPosition;
    }

    function getLastCoordinates() as [Double, Double]? {
        if (_lastPosition != null) {
            return _lastPosition.toDegrees();
        }
        return null;
    }

    // Equirectangular flat-surface approximation for fast on-watch distance calculation
    function calculateDistance(lat1 as Double, lon1 as Double, lat2 as Double, lon2 as Double) as Float {
        var R = 6371000.0; // Earth radius in meters
        var dLat = (lat2 - lat1) * Math.PI / 180.0;
        var dLon = (lon2 - lon1) * Math.PI / 180.0;

        var meanLat = (lat1 + lat2) * Math.PI / 360.0;
        var x = dLon * Math.cos(meanLat);
        var y = dLat;

        return (Math.sqrt(x*x + y*y) * R).toFloat();
    }
}
