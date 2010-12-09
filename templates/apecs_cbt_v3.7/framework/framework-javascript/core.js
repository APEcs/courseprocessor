// JavaScript

/***
 *** Page initializations
 ***/
 
window.onresize = function (evt) {
	formatBackToTopLink();
};

function initializeFrameworkPage(depth) 
{
	var pathToImage = 'framework-images/header/blue/';
	while(depth > 1)
	{
		pathToImage = '../' + pathToImage; 
		depth--;
	}
	MM_preloadImages(pathToImage + 'logo-hover.gif', 
					 pathToImage + 'nav-button-left-hover.gif', 
					 pathToImage + 'nav-button-right-hover.gif');

	formatBackToTopLink();
}

function initializeCourseIndexPage() 
{
	var pathToImage = 'framework-images/header/blue/';
	MM_preloadImages(pathToImage + 'logo-hover.gif', 
					 pathToImage + 'nav-button-coursemap-hover.gif', 
					 pathToImage + 'nav-button-courseindex-hover.gif');

	formatBackToTopLink();
}

function initializeThemeIndexPage() 
{
	var pathToImage = '../framework-images/header/blue/';
	MM_preloadImages(pathToImage + 'logo-hover.gif', 
					 pathToImage + 'nav-button-thememap-hover.gif', 
					 pathToImage + 'nav-button-themeindex-hover.gif');

	formatBackToTopLink();
}

function initializeStepPage(color) 
{
	var path = '../../framework-images/header';
	var pathToImage = path + '/' + color + '/';
	MM_preloadImages(pathToImage + 'logo-hover.gif', 
					 pathToImage + 'nav-button-left-hover.gif', 
					 pathToImage + 'nav-button-right-hover.gif');
	
	formatBackToTopLink();
}

 
/***
 *** Image Roll-over effects
 ***/
 
function MM_swapImgRestore() 
{ //v3.0
  var i,x,a=document.MM_sr; for(i=0;a&&i<a.length&&(x=a[i])&&x.oSrc;i++) x.src=x.oSrc;
}

function MM_preloadImages() 
{ //v3.0
  var d=document; if(d.images){ if(!d.MM_p) d.MM_p=new Array();
    var i,j=d.MM_p.length,a=MM_preloadImages.arguments; for(i=0; i<a.length; i++)
    if (a[i].indexOf("#")!=0){ d.MM_p[j]=new Image; d.MM_p[j++].src=a[i];}}
}

function MM_findObj(n, d) 
{ //v4.01
  var p,i,x;  if(!d) d=document; if((p=n.indexOf("?"))>0&&parent.frames.length) {
    d=parent.frames[n.substring(p+1)].document; n=n.substring(0,p);}
  if(!(x=d[n])&&d.all) x=d.all[n]; for (i=0;!x&&i<d.forms.length;i++) x=d.forms[i][n];
  for(i=0;!x&&d.layers&&i<d.layers.length;i++) x=MM_findObj(n,d.layers[i].document);
  if(!x && d.getElementById) x=d.getElementById(n); return x;
}

function MM_swapImage() 
{ //v3.0
  var i,j=0,x,a=MM_swapImage.arguments; document.MM_sr=new Array; for(i=0;i<(a.length-2);i+=3)
   if ((x=MM_findObj(a[i]))!=null){document.MM_sr[j++]=x; if(!x.oSrc) x.oSrc=x.src; x.src=a[i+2];}
}


/***
 *** Drop-down menu hover support for IE
 ***/
 
sfHover = function() 
{
	var sfEls = document.getElementById("nav").getElementsByTagName("LI");
	for (var i=0; i<sfEls.length; i++) {
		sfEls[i].onmouseover=function() {
			this.className+=" sfhover";
		}
		sfEls[i].onmouseout=function() {
			this.className=this.className.replace(new RegExp(" sfhover\\b"), "");
		}
	}
}
if (window.attachEvent) window.attachEvent("onload", sfHover);


/***
 *** Date writing support for footer
 ***/

function writeCurrentYear() 
{
	var mydate=new Date()
	var year=mydate.getYear()
	if (year < 1000) {
		year+=1900
	}
	document.write(year);
}


/***
 *** Cookie reading and writing support
 ***/
 
function getCbtPath(cbtDepth)
{
	var currentPage = location.href;
	var cbtPath = dotdot(currentPage, cbtDepth);
	return cbtPath;
}

function updateThemeView()
{
	var cbtPath = getCbtPath(2);

	/* Switch view if a stored cookie is found and points to the index */
	var themeViewTypeKey = cbtPath + "[themeviewtype]";
	var themeViewType = readCookie(themeViewTypeKey);
	if(themeViewType != null && themeViewType == "themeindex")
	{
		location.href = "./themeindex.html";
	}
}

function setThemeView(type)
{
	var cbtPath = getCbtPath(2);
	var themeViewTypeKey = cbtPath + "[themeviewtype]";
	writeCookie(themeViewTypeKey, type);
}

function updateCourseView()
{
	var cbtPath = getCbtPath(1);

	/* Switch view if a stored cookie is found and points to the index */
	var courseViewTypeKey = cbtPath + "[courseviewtype]";
	var courseViewType = readCookie(courseViewTypeKey);
	if(courseViewType != null && courseViewType == "courseindex")
	{
		location.href = "./courseindex.html";
	}
}

function setCourseView(type)
{
	var cbtPath = getCbtPath(1);
	var courseViewTypeKey = cbtPath + "[courseviewtype]";
	writeCookie(courseViewTypeKey, type);
}

function setLastViewedPage(cbtDepth)
{
	var cbtPath = getCbtPath(cbtDepth);
	var lastPageKey = cbtPath + "[lastpage]";
	var currentPage = location.href;
	writeCookie(lastPageKey, currentPage);
}

/*
 * If a last viewed page cookie is stored, this function will write out 
 * the HTML for a "Last Viewed Page" style button.  This is intended only
 * to be called from the front page.
 */
function writeLastViewedPageButton()
{
	var cbtPath = getCbtPath(1);
	var lastPageKey = cbtPath + "[lastpage]";
	var lastPageUrl = readCookie(lastPageKey);
	if(lastPageUrl != null && lastPageUrl.length > 0)
	{
		document.write('<a href="' + lastPageUrl + '">Last Viewed Page</a>');
	}
}


/* 
 * Writes a cookie name-value pair.
 * Example usage:
 * writeCookie("myCookie", "my name");
 * Stores the string "my name" in the cookie "myCookie" which expires after 1 year.
 */
function writeCookie(name, value)
{
  var expire = new Date((new Date()).getTime() + (1000*60*60*24*7*52)); // one year
  expire = "; expires=" + expire.toGMTString();
  document.cookie = name + "=" + escape(value) + expire + "; path=/";
}

/*
 * Reads a cookie with given name.
 * Example usage:
 * alert( readCookie("myCookie") );
 */ 
function readCookie(name)
{
  var cookieValue = "";
  var search = name + "=";
  if(document.cookie.length > 0)
  { 
    offset = document.cookie.indexOf(search);
    if (offset != -1)
    { 
      offset += search.length;
      end = document.cookie.indexOf(";", offset);
      if (end == -1) end = document.cookie.length;
      cookieValue = unescape(document.cookie.substring(offset, end))
    }
  }
  return cookieValue;
}

/* 
 * Returns a path shifted up by 'dotlevels' number of directories 
 */
function dotdot(path, dotlevels) 
{
	if(dotlevels == null) dotlevels = 1;
	var dotdotCount = 0;
	while(dotdotCount < dotlevels)
	{
		var index = path.lastIndexOf("/");
		path = path.substr(0, index);
		dotdotCount++;
	}
	return path;
}



/***
 *** Pop-up window functions
 ***/ 

msgWindow = null;

function OpenPopup(newURL, title, width, height)
{
    winl = (screen.width - width) / 2;
    wint = (screen.height - height) / 2;
    
    if(msgWindow != null) {
        msgWindow.close();
        msgwindow = null;
    }

    winprops = 'toolbar=no,menubar=no,location=no,scrollbars=yes,resizable=yes,width='+width+',height='+height+',left='+winl+',top='+wint;
    msgWindow = this.open(newURL, title, winprops);
    msgWindow.opener = this;
	if (window.focus) {msgWindow.focus()}
	return false;
}

function OpenWindow(newURL, title)
{
    msgWindow = this.open(newURL, title);
    if (window.focus) {msgWindow.focus()}
}

function openURL(newURL) 
{
    opener.location.href = newURL;
    this.close();
    msgWindow = null;
}


/***
 *** Back to top link dynamic hidding
 ***/

function formatBackToTopLink() 
{
	var wh = getWindowHeight(); // Window Height
	var d = document.getElementById('page') // Get div element
	var dh = d.offsetHeight // div height
	var toplink = document.getElementById('backtotop');
	if(dh < wh)
	{
		toplink.className+=' accesshide';
	}
	else
	{
		toplink.className=toplink.className.replace(new RegExp(" accesshide\\b"), "");
	}
}


function getWindowHeight() 
{
	var windowHeight = 0;
		
	if (typeof(window.innerHeight) == 'number')
	{
		windowHeight = window.innerHeight;
	}
	else
	{
		if (document.documentElement && document.documentElement.clientHeight)
		{
			windowHeight = document.documentElement.clientHeight;
		}
	else
	{
		if (document.body && document.body.clientHeight)
			windowHeight = document.body.clientHeight; 
		}
	}		   
	return windowHeight;
}