// -*- mode: Javascript;-*-

using Toybox.Graphics;
using Toybox.Sensor as Sensor;
using Toybox.System as System;
using Toybox.WatchUi as Ui;
using Toybox.Application as App;
using Toybox.Attention as Attention;
using Toybox.Communications as Comm;

class CommListener extends Comm.ConnectionListener {
    function initialize() {
        Comm.ConnectionListener.initialize();
    }

    function onComplete() {
        System.println("Transmit Complete");
    }

    function onError() {
        System.println("Transmit Failed");
    }
}

class LoopWidgetView extends Ui.View {
    var invert = false;
    var chart;
    var have_connected = false;
   
    var lastUpdateTime;
    var eventualGlucose;
    var predictionDelta;
    var iob;
    var cob;
    var currentGlucose;
	
	function initialize() {
		Ui.View.initialize();
		
		System.println("sensor enabling");
		// if(Comm has :registerForPhoneAppMessages) {
        //    System.println("phone app messages");
            //Comm.registerForPhoneAppMessages(method(:onPhone));	
		//} else {
        
         	System.println("mailbox listener");
        /* 	if(Comm has :emptyMailbox) {
         		try {
         			 System.println("empty mailbox");
  					 Comm.emptyMailbox();
				} catch (ex) {}
			}
		*/
         	Comm.setMailboxListener(method(:onMail));
        
		System.println("sensor enabling done");
	}
		
    function toggle_colors() {
        invert = !invert;
    }

    //! Load your resources here
    function onLayout(dc) {
    }

    //! Restore the state of the app and prepare the view to be shown
    function onShow() {
        if (model == null) {
            model = new PersistentChartModel();
            model.read_data();
            chart = new Chart(model);

            var app = App.getApp();
            if (app.getProperty(INVERT) == true) {
                invert = true;
            }
        }
        
        System.println("init listener");
		var listener = new CommListener();
        System.println("init listener2");
        Comm.transmit("ready", null, listener);
        System.println("init listener3");
        
        // Testing
        
		model.new_value(null);	
		model.new_value(null);
		model.new_value(null);
		model.new_value(null);
		model.new_value(null);	
		model.new_value(null);
		model.new_value(null);
		model.new_value(null);
		model.new_value(100.0);
		model.new_value(100.0);
		model.new_value(90.0);
		model.new_value(120.0);
		
		model.new_value(200.0);
		model.new_value(240.0);
		model.new_value(250.0);
		model.new_value(270.0);
		model.new_value(200.0);
		model.new_value(140.0);
		model.new_value(110.0);
		model.new_value(90.0);
		model.new_value(80.0);
		model.new_value(50.0);
		model.new_value(70.0);
		model.new_value(100.0);
		model.new_value(110.0);
		iob=12.34;
		cob=123.45;
		eventualGlucose=270.2;
		currentGlucose=55;
		lastUpdateTime = Time.now().value() - 11*60;
		predictionDelta = -55;
		
		Ui.requestUpdate();
	
    }

    //! Called when this View is removed from the screen. Save the
    //! state of your app here.
    function onHide() {
        // Write here for the widget case
        model.write_data();
        var app = App.getApp();
        app.setProperty(INVERT, invert);
    }

    //! Update the view
    function onUpdate(dc) {
        var fg = invert ? Graphics.COLOR_BLACK : Graphics.COLOR_WHITE;
        var bg = invert ? Graphics.COLOR_WHITE : Graphics.COLOR_BLACK;

        dc.setColor(fg, bg);
        dc.clear();
        dc.setColor(fg, Graphics.COLOR_TRANSPARENT);

        var duration_label;
        
        
        if(lastUpdateTime == null || predictionDelta == null) { 
        		duration_label = "Waiting";
        	} else {
       	 	if((Time.now().value() - lastUpdateTime)/60 > 10) { dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_DK_BLUE); }
        		duration_label = Math.round((Time.now().value() - lastUpdateTime)/60).format("%.0f") + " MIN AGO (" + Math.round(predictionDelta).format("%+.0f") + ")";
        }
        text(dc, 109, 192, Graphics.FONT_XTINY, duration_label);
    		dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        
        // TODO this is maybe just a tiny bit too ad-hoc
        if (dc.getWidth() == 218 && dc.getHeight() == 218) {
            // Fenix 3
            text(dc, 109, 15, Graphics.FONT_TINY, "BG");
            
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            text(dc, 56, 40, Graphics.FONT_XTINY, "COB:" + fmt_num(cob));
            text(dc, 56, 54, Graphics.FONT_XTINY, "IOB:" + fmt_decimal(iob));
            
            dc.setColor(chart.colorForGlucose(eventualGlucose), Graphics.COLOR_TRANSPARENT); 
            text(dc, 160, 47, Graphics.FONT_SMALL, "->" + fmt_num(eventualGlucose));
            
            dc.setColor(chart.colorForGlucose(currentGlucose), Graphics.COLOR_TRANSPARENT); 
            text(dc, 109, 45, Graphics.FONT_NUMBER_MEDIUM, fmt_num(currentGlucose) );
             
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
                
            
            chart.draw(dc, [23, 75, 195, 172], fg, Graphics.COLOR_RED,
                       30, true, true, true, self);
        } else if (dc.getWidth() == 205 && dc.getHeight() == 148) {
            // Vivoactive, FR920xt, Epix
            text(dc, 70, 25, Graphics.FONT_MEDIUM, "HR");
            text(dc, 120, 25, Graphics.FONT_NUMBER_MEDIUM,
                 fmt_num(model.get_current()));
            text(dc, 102, 135, Graphics.FONT_XTINY, duration_label);
            chart.draw(dc, [10, 45, 195, 120], fg, Graphics.COLOR_RED,
                       30, true, true, false, self);
        }
    }

    function fmt_num(num) {
        if (num == null) {
            return "---";
        }
        else {
            return "" + num.format("%.0f");
        }
    }
    
    function fmt_decimal(num) {
        if (num == null) {
            return "---";
        }
        else {
            return "" + num.format("%.1f");
        }
    }
    
    
    
    function text(dc, x, y, font, s) {
        dc.drawText(x, y, font, s,
                    Graphics.TEXT_JUSTIFY_CENTER|Graphics.TEXT_JUSTIFY_VCENTER);
    }

    var vibrateData = [new Attention.VibeProfile( 25, 100),
                       new Attention.VibeProfile( 50, 100),
                       new Attention.VibeProfile( 75, 100),
                       new Attention.VibeProfile(100, 100),
                       new Attention.VibeProfile( 75, 100),
                       new Attention.VibeProfile( 50, 100),
                       new Attention.VibeProfile( 25, 100)];

  	function onMail(mailIter) {
   		System.println("onmail");
        var mail;

        mail = mailIter.next();
 		System.println("onmail2");
        
        while(mail != null) {
			System.println("onmail3");
        		System.println(mail.toString());
			System.println("onmail4");
            //model.new_value(mail.get("glucose"));
			var history = mail.get("glucose");
    			if(history != null) {
    				for (var i = 0; i < 12-history.size(); i++) { 
    					model.new_value(null);
    				}      
    				for (var i = 1; i < history.size(); i++) {
               		model.new_value(history[i]);
               		currentGlucose = history[i];
               	}
            } 
            var forecast = mail.get("glucoseforecast");
    			if(forecast != null) {
    				for (var i = 1; i < forecast.size(); i++) {
               		model.new_value(forecast[i]);
               		//currentGlucose = history[i];
               	}
            } 
            
            System.println("onmail4.5");
    			lastUpdateTime = mail.get("glucosetime");
    			System.println("onmail5");
    			predictionDelta = mail.get("predictiondelta");
    			System.println("onmail6");
    			iob = mail.get("iob");
    			cob = mail.get("cob");
    			eventualGlucose = mail.get("eventualglucose");
    			
            mail = mailIter.next();
        }

        Comm.emptyMailbox();
        Ui.requestUpdate();
    }
}


class LoopWidgetDelegate extends Ui.InputDelegate {
    function initialize() {
		Ui.InputDelegate.initialize();
	}
	
    function onKey(evt) {
        if (evt.getKey() == Ui.KEY_ENTER) {
            Ui.pushView(new Rez.Menus.MainMenu(), new MenuDelegate(),
                        Ui.SLIDE_LEFT);
            return true;
        }
        return false;
    } 
}

class MenuDelegate extends Ui.MenuInputDelegate {
     function initialize() {
		Ui.MenuInputDelegate.initialize();
	}
	
    function onMenuItem(item) {
        if (item == :set_period) {
            Ui.pushView(new Rez.Menus.PeriodMenu(), new PeriodMenuDelegate(),
                        Ui.SLIDE_LEFT);
            return true;
        }
        else if (item == :swap_colors) {
            view.toggle_colors();
            return true;
        } 
        Ui.popView(Ui.SLIDE_RIGHT);
        return true;
    }
}

class PeriodMenuDelegate extends Ui.MenuInputDelegate {
     function initialize() {
		Ui.MenuInputDelegate.initialize();
	}
	
	function onMenuItem(item) {
        if (item == :min_2) {
            model.set_range_minutes(2.5);
        }
        else if (item == :min_5) {
            model.set_range_minutes(5);
        }
        else if (item == :min_10) {
            model.set_range_minutes(10);
        }
        else if (item == :min_15) {
            model.set_range_minutes(15);
        }
        else if (item == :min_30) {
            model.set_range_minutes(30);
        }
        else if (item == :min_45) {
            model.set_range_minutes(45);
        }
        else if (item == :hour_1) {
            model.set_range_minutes(60);
        }
        else if (item == :hour_2) {
            model.set_range_minutes(120);
        }
        else if (item == :hour_8) {
            model.set_range_minutes(480);
        }
        else if (item == :hour_24) {
            model.set_range_minutes(1440);
        }
        Ui.popView(Ui.SLIDE_RIGHT);
        return true;
    } 
} 

