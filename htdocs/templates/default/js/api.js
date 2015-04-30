/** Generate a request path to send AJAX requests to. This will
 *  automatically compensate for missing url fragments if needed.
 *
 * @param block     The system block the API is provided by.
 * @param operation The API operation to perform.
 * @param base      Optional base path to force for operations.
 * @return A string containing the request path to use.
 */
function api_request_path(block, operation, base)
{
    var reqpath = window.location.pathname;

    if(!base) {
        // First, determine whether the path already contains the block, if so back up to it
        var blockpos = reqpath.indexOf(block);
        if(blockpos != -1) {
            reqpath = reqpath.substring(0, blockpos + block.length);
        }
    } else {
        reqpath = base;
    }

    // Ensure the request path has a trailing slash
    if(reqpath.charAt(reqpath.length - 1) != '/') reqpath += '/';

    // Does the current page end in news/? If not, add it
    if(!reqpath.test(block+'\/$')) reqpath += (block + "/");

    // Add the api call
    reqpath += "api/" + operation + "/";

    return reqpath;
}


/** Attach a spinner to the specified container, and fade it in.
 *  Once the spinner is no longer needed, you must call hide_spinner()
 *  to remove the spinner (or destroy the container), or horrible things
 *  will happen.
 *
 * @param container The container to add the spinner to.
 * @param position  The position to add the spinner in (see Element.inject)
 */
function show_spinner(container, position)
{
    if(!position) position = 'bottom';

    if(!container.spinimg) {
        container.spinimg = new Element('img', {src: spinner_url,
                                                width: '16',
                                                height: '16',
                                                'class': 'spinner'});
        container.spinimg.inject(container, position);
        container.spinimg.fade('in');
    }
}


/** Remove a previously-added spinner from a container. This will
 *  fade out and then destroy a spinner added to the container with
 *  show_spinner().
 *
 * @param container The container to remove the spinner from.
 */
function hide_spinner(container)
{
    if(container.spinimg) {
        container.spinimg.fade('out').get('tween').chain(function() { container.spinimg.destroy();
                                                                      container.spinimg = null; });
    }
}