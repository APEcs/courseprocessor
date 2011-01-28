/* Fancier jump scrolling, in theory.
 */
new Fx.SmoothScroll({
	duration: 1000
},window);

/* Add the rollover for the jump image that appears on most stages.
 */
window.addEvent('domready', function() {
    $$('img.pathimg').each(function(element, index) {
        var src       = element.getProperty('src');
        var extension = src.substring(src.lastIndexOf('.'),src.length);
        element.addEvent('mouseenter', function() { element.setProperty('src', src.replace(extension, '_over' + extension)); });
        element.addEvent('mouseleave', function() { element.setProperty('src', src); });
    });
});
