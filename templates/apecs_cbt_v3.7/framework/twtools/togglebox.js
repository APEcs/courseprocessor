var ToggleBox = new Class(
{
    //implements
    Implements: [Options,Events],
    
    // options
    options: 
    {
        ctrlClass: 'div.togglebox-ctrl',
        bodyClass: 'div.togglebox-body',
        hideText: '[hide]',
        showText: '[show]',
        duration: 500
    },

    // initialization
    initialize: function(element, options) {
        //set options
        this.setOptions(options);

        this.control = element.getElement(this.options.ctrlClass);
        this.body    = element.getElement(this.options.bodyClass);

        this.control.innerHTML = this.options.showText; 
        this.isVisible = false;
        this.body.dissolve({duration: 0});

        this.control.addEvent('click', function() {
            if(this.isVisible) {
                this.body.dissolve({duration: this.options.duration});
                this.control.innerHTML = this.options.showText;
            } else {
                this.body.reveal({duration: this.options.duration});
                this.control.innerHTML = this.options.hideText;
            }
            this.isVisible = !this.isVisible;
        }.bind(this));
    },
});

window.addEvent('domready', function() { 

    $$('div.togglebox').each(function(element,index) {
        new ToggleBox(element);
    });
});
