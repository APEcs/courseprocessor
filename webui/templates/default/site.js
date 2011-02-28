
window.addEvent('domready', function() {
    $$('a.ext').each(function(element, index) {
        element.target = '_blank';
    });    
});