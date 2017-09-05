// -*- mode: Javascript;-*-

using Toybox.Application as App;

var view;
var model;

enum
{
    LAST_VALUES,
    LAST_VALUE_TIME,
    RANGE_MULT,
    INVERT
}

class LoopWidgetApp extends App.AppBase {

 	function initialize() {
        AppBase.initialize();
    }
    
    function onStart(state) {
        view = new LoopWidgetView();
    }

    function onStop(state) {
        // Write here for the app case
        model.write_data();
    }

    function getInitialView() {
        return [view, new LoopWidgetDelegate()];
    }
}
