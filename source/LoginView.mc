import Toybox.WatchUi;
import Toybox.Lang;
import Tinymetrix;

// -- Login form (native Menu2) --
// Items: Email / Password / Connect
// Text input via WatchUi.TextPicker (native virtual keyboard).

class LoginMenu extends WatchUi.Menu2 {
    function initialize() {
        Menu2.initialize({:title => (WatchUi.loadResource(Rez.Strings.LoginTitle) as String)});

        var savedEmail = getApp().getUserEmail();
        var emailSub   = (savedEmail != null && savedEmail.length() > 0)
            ? savedEmail : "";

        addItem(new WatchUi.MenuItem((WatchUi.loadResource(Rez.Strings.LoginEmail) as String),       emailSub,             :email,    {}));
        addItem(new WatchUi.MenuItem((WatchUi.loadResource(Rez.Strings.LoginPassword) as String),  "",                    :password, {}));
        addItem(new WatchUi.MenuItem((WatchUi.loadResource(Rez.Strings.LoginConnect) as String),  null,              :connect,  {}));
    }
}

// -- Login menu delegate --

class LoginMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var _email    as String = "";
    private var _password as String = "";

    // Reference to the "Account" item in the main menu (updated after login)
    private var _parentAccountItem as WatchUi.MenuItem or Null;

    // Pending reservation (when coming from the station list)
    private var _pendingStationId   as String or Null;
    private var _pendingStationName as String or Null;

    // "Connect" item reference for showing status
    private var _connectItem as WatchUi.MenuItem or Null = null;

    // Reference to the menu itself for updating subtitles
    private var _menu as LoginMenu;

    function initialize(menu as LoginMenu,
                        parentItem as WatchUi.MenuItem or Null,
                        pendingId   as String or Null,
                        pendingName as String or Null) {
        Menu2InputDelegate.initialize();
        _menu               = menu;
        _parentAccountItem  = parentItem;
        _pendingStationId   = pendingId;
        _pendingStationName = pendingName;

        // Pre-fill credentials from saved email (user can change them by tapping each field)
        var saved = getApp().getUserEmail();
        _email    = (saved != null && saved.length() > 0) ? saved : "";
        _password = "";
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();

        if (id == :email) {
            WatchUi.pushView(
                new WatchUi.TextPicker(_email),
                new EmailPickerDelegate(item, self),
                WatchUi.SLIDE_UP
            );

        } else if (id == :password) {
            WatchUi.pushView(
                new WatchUi.TextPicker(""),
                new PasswordPickerDelegate(item, self),
                WatchUi.SLIDE_UP
            );

        } else if (id == :connect) {
            _connectItem = item;
            if (_email.length() == 0 || _password.length() == 0) {
                item.setSubLabel((WatchUi.loadResource(Rez.Strings.LoginMissingFields) as String));
                WatchUi.requestUpdate();
                return;
            }
            item.setSubLabel((WatchUi.loadResource(Rez.Strings.LoginConnecting) as String));
            WatchUi.requestUpdate();
            getApp().biciMadService.loginUser(_email, _password, method(:onLoginDone));
        }
    }

    // Called by EmailPickerDelegate when the email is confirmed
    function setEmail(text as String, emailItem as WatchUi.MenuItem) as Void {
        _email = text;
        getApp().setUserEmail(text);
        emailItem.setSubLabel(text);
        WatchUi.requestUpdate();
    }

    // Called by PasswordPickerDelegate when the password is confirmed
    function setPassword(text as String, passItem as WatchUi.MenuItem) as Void {
        _password = text;
        passItem.setSubLabel("••••••••");
        WatchUi.requestUpdate();
    }

    function onLoginDone(success as Boolean, token as String?) as Void {
        if (success && token != null) {
            getApp().setUserToken(token);

            // Track login event and set user ID for Tinymetrix
            var email = getApp().getUserEmail();
            if (email != null) {
                Tinymetrix.Client.setUserId(email);
                Tinymetrix.Client.track("login");
            }

            // Update the "Account" item in the main menu if it exists
            if (_parentAccountItem != null) {
                _parentAccountItem.setLabel((WatchUi.loadResource(Rez.Strings.MenuLogout) as String));
                _parentAccountItem.setSubLabel(getApp().getUserEmail());
            }

            WatchUi.popView(WatchUi.SLIDE_DOWN); // close LoginMenu

            // If coming from a station, open the reservation view directly
            if (_pendingStationId != null && _pendingStationName != null) {
                var rv = new ReservationView(_pendingStationId, _pendingStationName, token);
                WatchUi.pushView(rv, new ReservationDelegate(rv), WatchUi.SLIDE_UP);
            }
        } else {
            if (_connectItem != null) {
                _connectItem.setSubLabel((WatchUi.loadResource(Rez.Strings.LoginCredentialsError) as String));
            }
            WatchUi.requestUpdate();
        }
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}

// -- TextPickerDelegate for email input --

class EmailPickerDelegate extends WatchUi.TextPickerDelegate {
    private var _item     as WatchUi.MenuItem;
    private var _delegate as LoginMenuDelegate;

    function initialize(item as WatchUi.MenuItem, delegate as LoginMenuDelegate) {
        TextPickerDelegate.initialize();
        _item     = item;
        _delegate = delegate;
    }

    function onTextEntered(text as String, changed as Boolean) as Boolean {
        if (text.length() > 0) { _delegate.setEmail(text, _item); }
        return true;
    }

    function onCancel() as Boolean { return true; }
}

// -- TextPickerDelegate for password input --

class PasswordPickerDelegate extends WatchUi.TextPickerDelegate {
    private var _item     as WatchUi.MenuItem;
    private var _delegate as LoginMenuDelegate;

    function initialize(item as WatchUi.MenuItem, delegate as LoginMenuDelegate) {
        TextPickerDelegate.initialize();
        _item     = item;
        _delegate = delegate;
    }

    function onTextEntered(text as String, changed as Boolean) as Boolean {
        if (text.length() > 0) { _delegate.setPassword(text, _item); }
        return true;
    }

    function onCancel() as Boolean { return true; }
}
