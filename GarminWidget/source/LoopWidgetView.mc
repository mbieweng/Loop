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
   
    var lastGlucoseTime;
    var lastLoopTime;
    var eventualGlucose;
    var iob;
    var cob;
    var currentGlucose;
    var retrospectiveDifferential;
	var predictionDelta;
	var netBasal;
	
	function initialize() {
		Ui.View.initialize();
		//System.println("mailbox listener");
        Comm.setMailboxListener(method(:onMail));
        
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

            //var app = App.getApp();
            //if (app.getProperty(INVERT) == true) {
            //    invert = true;
            //}
        }
        
        requestData();
        
        // Test Data
         /* 
		model.new_value(100);	
		model.new_value(55);
		model.new_value(110);
		model.new_value(60);
		model.new_value(120);	
		model.new_value(130);
		
		model.new_value(140);
		model.new_value(120);
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
		iob=-12.34;
		cob=123.45;
		eventualGlucose=236;
		currentGlucose=55;
		lastGlucoseTime = Time.now().value() - 11*60;
		lastLoopTime = Time.now().value() - 3*60;
		predictionDelta = -55;
		netBasal = 2.322;
	
		checkAndAlert();
		Ui.requestUpdate();
		// end test section
		*/

    }
    
	function requestData() {
		System.println("init listener");
		var listener = new CommListener();
        System.println("init listener2");
        Comm.transmit("sendcontext", null, listener);
        System.println("init listener3");
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
        if(lastGlucoseTime == null || predictionDelta == null) { 
        		duration_label = "Waiting for data";
        	} else {
       	 	if((Time.now().value() - lastGlucoseTime)/60 > 10) { dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_YELLOW); }
        		duration_label = " " + Math.round((Time.now().value() - lastGlucoseTime)/60).format("%.0f") + " Min Ago ";
        }
        text(dc, 109, 192, Graphics.FONT_XTINY, duration_label);
    		dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
        
        // TODO this is maybe just a tiny bit too ad-hoc
        if (dc.getWidth() == 218 && dc.getHeight() == 218) {
            // Fenix 3
            
            if(lastLoopTime != null) {
	            var loopAge = (Time.now().value() - lastLoopTime)/60;
	            if (loopAge >= 15) { dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_RED); }
	            else if (loopAge >= 5) { dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT); }
	            else { dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT); } 
            }
            text(dc, 109, 8, Graphics.FONT_XTINY, " LOOP ");
            
            dc.setColor(fg, Graphics.COLOR_TRANSPARENT);
            
            var basalLabel;
          	if(netBasal == null) { basalLabel = "--- U"; }
            else { basalLabel =  "" + netBasal.format("%+.1f") + " U"; } 
            
            dc.drawText(79, 31, Graphics.FONT_XTINY,  basalLabel, Graphics.TEXT_JUSTIFY_RIGHT|Graphics.TEXT_JUSTIFY_VCENTER); 
  		    dc.drawText(79, 45, Graphics.FONT_XTINY, "COB: " + fmt_num(cob), Graphics.TEXT_JUSTIFY_RIGHT|Graphics.TEXT_JUSTIFY_VCENTER);
            dc.drawText(79, 59, Graphics.FONT_XTINY, "IOB: " + fmt_decimal(iob),  Graphics.TEXT_JUSTIFY_RIGHT|Graphics.TEXT_JUSTIFY_VCENTER);
            
            //dc.drawText(140, 58, Graphics.FONT_XTINY,  "    (" + fmt_num(predictionDelta) + ")", Graphics.TEXT_JUSTIFY_LEFT|Graphics.TEXT_JUSTIFY_VCENTER);
            
            
            setTextColorForGlucose(eventualGlucose, dc);
            dc.drawText(140, 45, Graphics.FONT_SMALL, "->" + fmt_num(eventualGlucose) + " ", Graphics.TEXT_JUSTIFY_LEFT|Graphics.TEXT_JUSTIFY_VCENTER);
                
            setTextColorForGlucose(currentGlucose, dc);
            text(dc, 109, 42, Graphics.FONT_NUMBER_MEDIUM, " " + fmt_num(currentGlucose) + " ");
             
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

	function setTextColorForGlucose(val, dc) {
		if(val==null) { dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT); }
    	  	else if(val<80) { dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_RED); }
    	   	else if(val>240) { dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);  /*dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_YELLOW);*/  }
    	   	else if(val>180) { dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);  }
    	    else { dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT); }
    	    
    	}
    	        
    function fmt_num(num) {
        if (num == null) {
            return "---";
        }
        else {
            return "" + num.format("%.0f");
        }
    }
    
    function fmt_plusminus(num) {
        if (num == null) {
            return "---";
        }
        else {
            return "" + num.format("%+f");
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

   
                       
   	function checkAndAlert() {
   		var alert = false;
   		
   		if(currentGlucose != null) {
   			if(currentGlucose < 80) { alert = true; }
   		}
   		
   		if(eventualGlucose != null) {
   			if(eventualGlucose < 80) { alert = true; }
   		}
   		
   		if(lastLoopTime != null) {
   			var loopAge = (Time.now().value() - lastLoopTime)/60;
            if (loopAge >= 15) { alert = true; }
        	}
        	
        	if(predictionDelta != null) {
   			if(predictionDelta.abs() > 40) { alert = true; }
        	}
   		
   		if(alert) {
	   		if (Attention has :vibrate) {
	   			var vibe = [new Attention.VibeProfile( 100, 100),
                       new Attention.VibeProfile( 0, 100),
                       new Attention.VibeProfile( 100, 300),
                       new Attention.VibeProfile( 0, 100),
                       new Attention.VibeProfile( 100, 100),
                       new Attention.VibeProfile( 0, 100),
                       new Attention.VibeProfile( 100, 300)
          
                      ];
	   			Attention.vibrate(vibe);
             }
	   	} else {
	   		if (Attention has :vibrate) {
	   			Attention.vibrate( [new Attention.VibeProfile(100, 50),
	   								new Attention.VibeProfile(0, 50),
	   								new Attention.VibeProfile(100, 50)] );
	   		}
	   	}
   	} 

  	function onMail(mailIter) {
   		var mail;

        mail = mailIter.next();
        while(mail != null) {
	    		System.println(mail.toString());
	        var history = mail.get("glucose");
    			if(history != null) {
    				for (var i = 0; i < 6-history.size(); i++) { 
    					model.new_value(null);
    				}      
    				for (var i = 1; i < history.size(); i++) {
               		model.new_value(history[i]);
               		currentGlucose = history[i];
               	}
            } 
            var forecast = mail.get("glucoseForecast");
    			if(forecast != null) {
    				for (var i = 1; i < forecast.size(); i++) {
               		model.new_value(forecast[i]);
               	}
            } 
            
            lastGlucoseTime = mail.get("lastGlucoseTime");
    			predictionDelta = mail.get("predictionDelta");
    			iob = mail.get("iob");
    			cob = mail.get("cob");
    			eventualGlucose = mail.get("eventualGlucose");
    		    lastLoopTime = mail.get("lastLoopTime");
    		    netBasal = mail.get("netBasal");
    		    mail = mailIter.next();
    		    
        }

        Comm.emptyMailbox();
        Ui.requestUpdate();
        checkAndAlert();
    }
}


class LoopWidgetDelegate extends Ui.InputDelegate {
    function initialize() {
		Ui.InputDelegate.initialize();
	}
	
    function onKey(evt) {
        if (evt.getKey() == Ui.KEY_ENTER) {
            view.lastGlucoseTime = null;
            view.currentGlucose = null;
            Ui.requestUpdate();
           	view.requestData();
           	 
           // Ui.pushView(new Rez.Menus.MainMenu(), new MenuDelegate(),
           //             Ui.SLIDE_LEFT);
            return true;
        }
        return false;
    } 
}

/*
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
*/
