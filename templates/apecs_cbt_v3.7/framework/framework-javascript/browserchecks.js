// JavaScript Document

<!-- Set the minimum Flash version here -->
var minFlashVersion = 7;
var flashCheck = false;

<!-- Set some boolean variables up to report result of the checks -->
var browserCheck = false;
var screenResCheck = false;

// Grab some infomation about the browser
var name = navigator.appName;
var codename = navigator.appCodeName;
var version = navigator.appVersion.substring(0,4);
version = parseFloat(version);
var screenWidth = screen.width;
var screenHeight = screen.height;
	
// Minimum requirement is that we are using a version 4 browser
if (version >= 4) {	
	browserCheck = true; 
}

// Recommended minimum screen resolution is 1024 x 768
if((screenWidth >= 1024) || (screenHeight >= 768)) { 
	screenResCheck = true;
}


function runBrowserChecks() 
{
	// Browser version error handling 
	
	if(!browserCheck) 
	{
	document.write('<h2><span class="warn">WARNING:</span> Browser version needs updating or is not supported</h2>' +
		'<div class="shadedbox">' +
		'<p>The  Computer Based Training (CBT) package has detected that your browser ' +
		'is either too old or is not supported by the CBT package.</p>' +
		'<p>While this CBT package <em>may</em> work in your browser it is not possible to guarantee that all ' +
		'the features will work as documented. This CBT package recommeded for use with ' +
		'up-to-date versions of Microsoft Internet Explorer (for Windows), Mozilla and Firefox '+
		'(for Windows and Linux), and Safari (for Macintosh).  If you do not have access to the' +
		'recommended browsers, please contact your systems administrator.</p>' +
		'<p>You may try to continue loading the  CBT package by clicking the ' +
		'link below, however you may experience problems which your course tutor ' +
		'may not be able to assist you with.</p>' +
		'</div>');
	}
	
	// Screen resolution error handling 
	
	if(!screenResCheck) 
	{
		document.write('<h2><span class="warn">WARNING:</span> Screen resolution issues detected</h2>' +
		'<div class="shadedbox">' +
		'<p>You have started this Computer Based Training (CBT) package on a screen ' +
		'less than 1024 pixels wide by 768 pixels high. While it is possible to ' +
		'use the package on screens below this resolution it is possible that ' +
		'you may encounter layout problems and additional scrolling of content ' +
		'pages will be required.</p>' +
		'<p>It is strongly recommended that you increase the resolution of your ' +
		'screen to at least 1024x768 pixels to use this CBT package effectively. ' +
		'If you are unsure about how to do this please consult your operating ' +
		'system\'s documentation, your system\'s administrator or your course tutor. ' +
		'After increasing the screen resolution, you may need restart your browser before ' +
		'trying this CBT package again.</p></div>');
	}
	
	// Flash detection and error handling 
	
	var flashVersion = deconcept.SWFObjectUtil.getPlayerVersion();
	
	document.write('<div id="flashwarning">' +
	'<h2><span class="warn">WARNING:</span> ');
	
	if(flashVersion['major'] == 0)
	{
	document.write('Flash player not installed in browser</h2>' +
		'<div class="shadedbox">' +
		'<p>You do not appear have the Flash plugin installed in your browser. ' +
		'This CBT package requires an up-to-date version of the Flash Player ' +
		'(at least <strong>version ' + minFlashVersion + '</strong>) to be installed in your browser.</p>')
	}
	else if((flashVersion['major'] > 0) && (flashVersion['major'] < minFlashVersion))
	{
	document.write('Flash player version needs updating in browser</h2>' +
		'<div class="shadedbox">' +
		'<p>The version of the Flash plugin installed in your browser is a lower version ' +
		'than required to reliably use all features of this Computer Based Training (CBT) package. ' +
		'You appear to have Flash <strong>version ' + flashVersion['major'] + '</strong> and ' +
		'this CBT package requires at least <strong>version ' + minFlashVersion + '</strong> to be installed.</p>');
	}
	document.write('<p>You can install the latest version of the Flash Player by visting ' +
		'<a href="http://www.macromedia.com/go/getflashplayer" target="_blank">' +
		'http://www.macromedia.com/go/getflashplayer</a></p>' +
		'<p>After installing the Flash plugin, you may need restart your browser before ' +
		'trying this CBT package again.</p>' +
		'</div>' +
		'</div>');
	
	// If Flash meets minimum version then remove the warning from the page 
	if (document.getElementById && (flashVersion['major'] >= minFlashVersion))
	{
		document.getElementById('flashwarning').innerHTML = "";
		flashCheck = true;
	}		
	
	
	
	
	
	// If any tests failed, give the option of continuing anyway
	
	if(browserCheck && screenResCheck && flashCheck)
	{
		document.location.href = "frontpage.html";
	}
	else
	{	
		document.write('<p>You may be able to continue without any problems.  ' +
		'<a href="frontpage.html" title="Continues to the CBT package front page">Ignore these warnings and ' +
		'continue regardless</a>.</p>');
	}
}
