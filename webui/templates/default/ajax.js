// AJAX code based on code in AutoSuggest from http://www.brandspankingnew.net

bsn = this;

if(typeof(bsn.Ajax) == "undefined")
    bsn.Ajax = {}

bsn.Ajax = function ()
{
    this.req = {};
    this.isIE = false;
}


bsn.Ajax.prototype.makeRequest = function (url, meth, onComp, onErr)
{
    if (meth != "POST")
        meth = "GET";
    
    this.onComplete = onComp;
    this.onError = onErr;
    
    var pointer = this;
    
    // branch for native XMLHttpRequest object
    if (window.XMLHttpRequest)
    {
        this.req = new XMLHttpRequest();
        this.req.onreadystatechange = function () { pointer.processReqChange() };
        this.req.open("GET", url, true); //
        this.req.send(null);
    // branch for IE/Windows ActiveX version
    } else if (window.ActiveXObject) {
        this.req = new ActiveXObject("Microsoft.XMLHTTP");
        if (this.req)
        {
            this.req.onreadystatechange = function () { pointer.processReqChange() };
            this.req.open(meth, url, true);
            this.req.send();
        }
    }
}


bsn.Ajax.prototype.processReqChange = function()
{
    // only if req shows "loaded"
    if (this.req.readyState == 4) {
        // only if "OK"
        if (this.req.status == 200)
        {
            this.onComplete( this.req );
        } else {
            this.onError( this.req.status );
        }
    }
}
