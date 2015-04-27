## @file
# This file contains the implementation of the WebUI block base class.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

## @class
#
package WebUI;

use strict;
use base qw(Webperl::Block); # Features are just a specific form of Block
use Webperl::Utils qw(join_complex path_join);
use CGI::Util qw(escape);
use Devel::StackTrace;
use DateTime::TimeZone;
use HTML::Entities;
use HTML::WikiConverter;
use Time::Local;
use Lingua::EN::Sentence qw(get_sentences);
use XML::Simple;

# ============================================================================
#  Constructor

## @cmethod $ new(%args)
# Overloaded constructor for WebUI block modules. This will ensure that a valid
# item id has been stored in the block object data.
#
# @param args A hash of values to initialise the object with. See the Block docs
#             for more information.
# @return A reference to a new WebUI object on success, undef on error.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(entitymap => { '&ndash;'  => '-',
                                                       '&mdash;'  => '-',
                                                       '&rsquo;'  => "'",
                                                       '&lsquo;'  => "'",
                                                       '&ldquo;'  => '"',
                                                       '&rdquo;'  => '"',
                                                       '&hellip;' => '...',
                                                       '&gt;'     => '>',
                                                       '&lt;'     => '<',
                                                       '&amp;'    => '&',
                                                       '&nbsp;'   => ' ',
                                                       '&#x200B;' => '',
                                        },
                                        @_)
        or return undef;

    return $self;
}


# ============================================================================
#  HTML generation support

## @method $ generate_webui_page($title, $content, $extrahead, $doclink)
# A convenience function to wrap page content in the standard page template. This
# function allows blocks to embed their content in a page without having to build
# the whole page including "common" items themselves. It should be called to wrap
# the content when the block's page_display is returning.
#
# @param title     The page title.
# @param content   The content to show in the page.
# @param extrahead Any extra directives to place in the header.
# @param doclink   The name of a document link to include in the userbar. If not
#                  supplied, no link is shown.
# @return A string containing the page.
sub generate_webui_page {
    my $self      = shift;
    my $title     = shift;
    my $content   = shift;
    my $extrahead = shift;
    my $doclink   = shift;

    my $userbar = $self -> {"module"} -> load_module("WebUI::Userbar");

    # Work out the current local offset from UTC in seconds.
    my @t = localtime();
    my $offset = timegm(@t) - timelocal(@t);

    # And a descriptive version of the timezone and DST status in the footer.
    my $dst = $self -> {"template"} -> replace_langvar($t[8] ? "FOOTER_TIMEDST" : "FOOTER_NODST");
    my $footer = $self -> {"template"} -> load_template("footer.tem", {"***timezone***"  => DateTime::TimeZone -> new(name => 'local') -> name(),
                                                                       "***dst***"       => $dst});

    return $self -> {"template"} -> load_template("page.tem", {"***extrahead***" => $extrahead || "",
                                                               "***title***"     => $title || "",
                                                               "***utcoffset***" => $offset,
                                                               "***footer***"    => $footer,
                                                               "***userbar***"   => ($userbar ? $userbar -> block_display($title, $self -> {"block"}, $doclink) : "<!-- Userbar load failed: ".$self -> {"module"} -> errstr()." -->"),
                                                               "***content***"   => $content});
}


## @method $ generate_errorbox($message, $title)
# Generate the HTML to show in the page when a fatal error has been encountered.
#
# @param message The message to show in the page.
# @param title   The title to use for the error. If not set "{L_FATAL_ERROR}" is used.
# @return A string containing the page
sub generate_errorbox {
    my $self    = shift;
    my $message = shift;
    my $title   = shift || "{L_FATAL_ERROR}";

    $self -> log("error:fatal", $message);

    $message = $self -> {"template"} -> message_box($title,
                                                    "error",
                                                    "{L_FATAL_ERROR_SUMMARY}",
                                                    $message,
                                                    undef,
                                                    "errorcore",
                                                    [ {"message" => $self -> {"template"} -> replace_langvar("SITE_CONTINUE"),
                                                       "colour"  => "blue",
                                                       "action"  => "location.href='{V_[scriptpath]}'"} ]);
    my $userbar = $self -> {"module"} -> load_module("WebUI::Userbar");

    # Build the error page...
    return $self -> {"template"} -> load_template("error/general.tem",
                                                  {"***title***"     => $title,
                                                   "***message***"   => $message,
                                                   "***extrahead***" => "",
                                                   "***userbar***"   => ($userbar ? $userbar -> block_display($title) : "<!-- Userbar load failed: ".$self -> {"module"} -> errstr()." -->"),
                                                  });
}


## @method $ generate_multiselect($name, $class, $idbase, $options, $selected)
# Generate a MultiSelect dropdown list (essentially a list of checkboxes that gets
# converted to a dropdown using the MultiSelect javascript module).
#
# @param name     The name of the multiselect option list.
# @param class    A class to add to the class attribute for the checkboxes in the list.
# @param idbase   A unique base name for the ID of checkboxes in the list.
# @param options  A reference to an array of option hashes. Each hash should contain
#                 `name` a short name used in the class, `id` a numeric ID used in the
#                 id and value attributes, and `desc` used in the label.
# @param selected A reference to a list of selected option IDs.
# @return A string containing the multiselect list checkboxes.
sub generate_multiselect {
    my $self     = shift;
    my $name     = shift;
    my $class    = shift;
    my $idbase   = shift;
    my $options  = shift;
    my $selected = shift;

    # Convert the selected list to a hash for faster lookup
    my %active = map { $_ => 1} @{$selected};

    my $result = "";
    foreach my $option (@{$options}) {
        $result .= $self -> {"template"} -> load_template("multisel-item.tem", {"***class***"   => $class,
                                                                                "***idbase***"  => $idbase,
                                                                                "***selname***" => $name,
                                                                                "***name***"    => $option -> {"name"},
                                                                                "***id***"      => $option -> {"id"},
                                                                                "***desc***"    => $option -> {"desc"},
                                                                                "***checked***" => $active{$option -> {"id"}} ? 'checked="checked"' : ''});
    }

    return $result;
}


# ============================================================================
#  Permissions/Roles related.

## @method $ check_permission($action, $contextid, $userid)
# Determine whether the user has permission to peform the requested action. This
# should be overridden in subclasses to provide actual checks.
#
# @param action    The action the user is attempting to perform.
# @param contextid The ID of the metadata context the user is trying to perform
#                  an action in. If this is not given, the root context is used.
# @param userid    The ID of the user to check the permissions for. If not
#                  specified, the current session user is used.
# @return true if the user has permission, false if they do not, undef on error.
sub check_permission {
    my $self      = shift;
    my $action    = shift;
    my $contextid = shift || $self -> {"system"} -> {"roles"} -> {"root_context"};
    my $userid    = shift || $self -> {"session"} -> get_session_userid();

    return $self -> {"system"} -> {"roles"} -> user_has_capability($contextid, $userid, $action);
}


## @method $ check_login()
# Determine whether the current user is logged in, and if not force them to
# the login form.
#
# @return undef if the user is logged in and has access, otherwise a page to
#         send back with a permission error. If the user is not logged in, this
#         will 'silently' redirect the user to the login form.
sub check_login {
    my $self = shift;

    # Anonymous users need to get punted over to the login form
    if($self -> {"session"} -> anonymous_session()) {
        $self -> log("error:anonymous", "Redirecting anonymous user to login form");

        # Need to set the cookies during the redirect, otherwise the current anon
        # session is lost, and a new one is made by the login form access, losing
        # the session data in the process.
        print $self -> {"cgi"} -> redirect(-uri => $self -> build_login_url(),
                                           -cookie => $self -> {"session"} -> session_cookies());
        exit;

    # Otherwise, permissions need to be checked
    } elsif(!$self -> check_permission("view")) {
        $self -> log("error:permission", "User does not have perission 'view'");

        # Logged in, but permission failed
        my $message = $self -> {"template"} -> message_box("{L_PERMISSION_FAILED_TITLE}",
                                                           "error",
                                                           "{L_PERMISSION_FAILED_SUMMARY}",
                                                           "{L_PERMISSION_VIEW_DESC}",
                                                           undef,
                                                           "errorcore",
                                                           [ {"message" => $self -> {"template"} -> replace_langvar("SITE_CONTINUE"),
                                                              "colour"  => "blue",
                                                              "action"  => "location.href='{V_[scriptpath]}'"} ]);
        my $userbar = $self -> {"module"} -> load_module("WebUI::Userbar");

        # Build the error page...
        return $self -> {"template"} -> load_template("error/general.tem",
                                                      {"***title***"     => "{L_PERMISSION_FAILED_TITLE}",
                                                       "***message***"   => $message,
                                                       "***extrahead***" => "",
                                                       "***userbar***"   => ($userbar ? $userbar -> block_display("{L_PERMISSION_FAILED_TITLE}") : "<!-- Userbar load failed: ".$self -> {"module"} -> errstr()." -->"),
                                                      });
    }

    return undef;
}


# ============================================================================
#  API support

## @method $ is_api_operation()
# Determine whether the feature is being called in API mode, and if so what operation
# is being requested.
#
# @return A string containing the API operation name if the script is being invoked
#         in API mode, undef otherwise. Note that, if the script is invoked in API mode,
#         but no operation has been specified, this returns an empty string.
sub is_api_operation {
    my $self = shift;

    my @api = $self -> {"cgi"} -> param('api');

    # No api means no API mode.
    return undef unless(scalar(@api));

    # API mode is set by placing 'api' in the first api entry. The second api
    # entry is the operation.
    return ($api[1] || "") if($api[0] eq 'api');

    return undef;
}


## @method $ api_errorhash($code, $message)
# Generate a hash that can be passed to api_response() to indicate that an error was encountered.
#
# @param code    A 'code' to identify the error. Does not need to be numeric, but it
#                should be short, and as unique as possible to the error.
# @param message The human-readable error message.
# @return A reference to a hash to pass to api_response()
sub api_errorhash {
    my $self    = shift;
    my $code    = shift;
    my $message = shift;

    return { 'error' => {
                          'info' => $message,
                          'code' => $code
                        }
           };
}


## @method $ api_html_response($data)
# Generate a HTML response containing the specified data.
#
# @param data The data to send back to the client. If this is a hash, it is
#             assumed to be the result of a call to api_errorhash() and it is
#             converted to an appropriate error box. Otherwise, the data is
#             wrapped in a minimal html wrapper for return to the client.
# @return The html response to send back to the client.
sub api_html_response {
    my $self = shift;
    my $data = shift;

    # Fix up error hash returns
    $data = $self -> {"template"} -> load_template("api/html_error.tem", {"***code***" => $data -> {"error"} -> {"code"},
                                                                          "***info***" => $data -> {"error"} -> {"info"}})
        if(ref($data) eq "HASH" && $data -> {"error"});

    return $self -> {"template"} -> load_template("api/html_wrapper.tem", {"***data***" => $data});
}


## @method $ api_response($data, %xmlopts)
# Generate an XML response containing the specified data. This function will not return
# if it is successful - it will return an XML response and exit.
#
# @param data    A reference to a hash containing the data to send back to the client as an
#                XML response.
# @param xmlopts Options passed to XML::Simple::XMLout. Note that the following defaults are
#                set for you:
#                - XMLDecl is set to '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>'
#                - KeepRoot is set to 0
#                - RootName is set to 'api'
# @return Does not return if successful, otherwise returns undef.
sub api_response {
    my $self    = shift;
    my $data    = shift;
    my %xmlopts = @_;
    my $xmldata;

    $xmlopts{"XMLDecl"} = '<?xml version="1.0" encoding="UTF-8" standalone="yes" ?>'
        unless(defined($xmlopts{"XMLDecl"}));

    $xmlopts{"KeepRoot"} = 0
        unless(defined($xmlopts{"KeepRoot"}));

    $xmlopts{"RootName"} = 'api'
        unless(defined($xmlopts{"RootName"}));

    $xmlopts{"NoEscape"} = 1
        unless(defined($xmlopts{"NoEscape"}));

    eval { $xmldata = XMLout($data, %xmlopts); };
    $xmldata = $self -> {"template"} -> load_template("xml/error_response.tem", { "***code***"  => "encoding_failed",
                                                                                  "***error***" => "Error encoding XML response: $@"})
        if($@);

    print $self -> {"cgi"} -> header(-type => 'text/xml',
                                     -charset => 'utf-8');
    print Encode::encode_utf8($xmldata);

    $self -> {"template"} -> set_module_obj(undef);
    $self -> {"messages"} -> set_module_obj(undef);
    $self -> {"system"} -> clear() if($self -> {"system"});
    $self -> {"session"} -> {"auth"} -> {"app"} -> set_system(undef) if($self -> {"session"} -> {"auth"} -> {"app"});

    $self -> {"dbh"} -> disconnect();
    $self -> {"logger"} -> end_log();

    exit;
}


# ============================================================================
#  General utility

## @method void log($type, $message)
# Log the current user's actions in the system. This is a convenience wrapper around the
# Logger::log function.
#
# @param type     The type of log entry to make, may be up to 64 characters long.
# @param message  The message to attach to the log entry, avoid messages over 128 characters.
sub log {
    my $self     = shift;
    my $type     = shift || "unknown";
    my $message  = shift;

    # It's possible for log to be called with no message, in which case it's at least
    # useful to know /where/ it was called from.
    if(!$message) {
        my $trace = Devel::StackTrace -> new();
        $message = "Empty message in log call from ".$trace -> as_string();
    }

    $message = "[Item:".($self -> {"itemid"} ? $self -> {"itemid"} : "none")."] $message";
    $self -> {"logger"} -> log($type, $self -> {"session"} -> get_session_userid(), $self -> {"cgi"} -> remote_host(), $message);
}


## @method $ set_saved_state()
# Store the current status of the script, including block, api, pathinfo, and querystring
# to session variables for later restoration.
#
# @return true on success, undef on error.
sub set_saved_state {
    my $self = shift;

    $self -> clear_error();

    my $res = $self -> {"session"} -> set_variable("saved_block", $self -> {"cgi"} -> param("block"));
    return undef unless(defined($res));

    my @pathinfo = $self -> {"cgi"} -> param("pathinfo");
    $res = $self -> {"session"} -> set_variable("saved_pathinfo", join("/", @pathinfo));
    return undef unless(defined($res));

    my @api = $self -> {"cgi"} -> param("api");
    $res = $self -> {"session"} -> set_variable("saved_api", join("/", @api));
    return undef unless(defined($res));

    # Convert the query parameters to a string, skipping the block, pathinfo, and api
    my @names = $self -> {"cgi"} -> param;
    my @qstring = ();
    foreach my $name (@names) {
        next if($name eq "block" || $name eq "pathinfo" || $name eq "api");

        my @vals = $self -> {"cgi"} -> param($name);
        foreach my $val (@vals) {
            push(@qstring, escape($name)."=".escape($val));
        }
    }
    $res = $self -> {"session"} -> set_variable("saved_qstring", join("&amp;", @qstring));
    return undef unless(defined($res));

    return 1;
}


## @method @ get_saved_state()
# A convenience wrapper around Session::get_variable() for fetching the state saved in
# build_login_url().
#
# @return An array of strings, containing the block, pathinfo, api, and query string.
sub get_saved_state {
    my $self = shift;

    # Yes, these use set_variable. set_variable will return the value in the
    # variable, like get_variable, except that this will also delete the variable
    return ($self -> {"session"} -> set_variable("saved_block"),
            $self -> {"session"} -> set_variable("saved_pathinfo"),
            $self -> {"session"} -> set_variable("saved_api"),
            $self -> {"session"} -> set_variable("saved_qstring"));
}


# ============================================================================
#  Things of which Man was Not Meant To Know (also support code)

## @method $ cleanup_entities($html)
# Wrangle the specified HTML into something that won't produce an unholy mess when
# passed to something that doesn't handle UTF-8 properly.
#
# @param html The HTML to process
# @return A somewhat cleaned-up string of HTML
sub cleanup_entities {
    my $self = shift;
    my $html = shift;

    $html =~ s/\r//g;
    return encode_entities($html, '^\n\x20-\x7e');
}


## @method $ make_markdown_body($html, $images)
# Convert the specified html into markdown text.
#
# @param html   The HTML to convert to markdown.
# @param images An optional reference to an array of images.
# @return The markdown version of the text.
sub make_markdown_body {
    my $self   = shift;
    my $html   = shift;
    my $images = shift || [];

    # Handle html entities that are going to break...
    foreach my $entity (keys(%{$self -> {"entitymap"}})) {
        $html =~ s/$entity/$self->{entitymap}->{$entity}/g;
    }

    my $converter = new HTML::WikiConverter(dialect => 'Markdown',
                                            link_style => 'inline',
                                            image_tag_fallback => 0,
                                            encoding => 'utf8');
    my $body = $converter -> html2wiki($html);

    # Clean up html the converter misses consistently
    $body =~ s|<br\s*/>|\n|g;
    $body =~ s|&gt;|>|g;

    my $imglist = "";
    for(my $i = 0; $i < 3; ++$i) {
        next unless($images -> [$i] -> {"location"});

        $imglist .= $self -> {"template"} -> load_template("Notification/Method/Email/md_image.tem", {"***url***" => $images -> [$i] -> {"location"}});
    }

    my $imageblock = $self -> {"template"} -> load_template("Notification/Method/Email/md_images.tem", {"***images***" => $imglist})
        if($imglist);

    return $self -> {"template"} -> load_template("Notification/Method/Email/markdown.tem", {"***text***" => $body,
                                                                                             "***images***" => $imageblock});
}


## @method $ truncate_text($text, $limit)
# Given a string containing plain text (NOT HTML!), produce a string
# that can be used as a summary. This truncates the specified text to the
# nearest sentence boundary less than the specified limit.
#
# @param text The text to truncate to a sentence boundary less than the limit.
# @param limit The number of characters the output may contain
# @return A string containing the truncated text
sub truncate_text {
    my $self  = shift;
    my $text  = shift;
    my $limit = shift;

    # If the text fits in the limit, just return it
    return $text
        if(length($text) <= $limit);

    # Otherwise, split into sentences and stick sentences together until the limit
    my $sentences = get_sentences($text);
    my $trunc = "";
    for(my $i = 0; $i < scalar(@{$sentences}) && (length($trunc) + length($sentences -> [$i])) <= $limit; ++$i) {
        $trunc .= $sentences -> [$i];
    }

    # If the first sentence was too long (trunc is empty), truncate to word boundaries instead
    $trunc = $self -> {"template"} -> truncate_words($text, $limit)
        if(!$trunc);

    return $trunc;
}

# ============================================================================
#  URL building

## @method $ build_login_url()
# Attempt to generate a URL that can be used to redirect the user to a login form.
# The user's current query state (course, block, etc) is stored in a session variable
# that can later be used to bring them back to the location this was called from.
#
# @return A relative login form redirection URL.
sub build_login_url {
    my $self = shift;

    # Store as much state as possible to restore after login (does not store POST
    # data!)
    $self -> set_saved_state();

    return $self -> build_url(block    => "login",
                              fullurl  => 1,
                              pathinfo => [],
                              params   => {},
                              forcessl => 1);
}


## @method $ build_return_url($fullurl)
# Pulls the data out of the session saved state, checks it for safety,
# and returns the URL the user should be redirected/linked to to return to the
# location they were attempting to access before login.
#
# @param fullurl If set to true, the generated url will contain the protocol and
#                host. Otherwise the URL will be absolute from the server root.
# @return A relative return URL.
sub build_return_url {
    my $self    = shift;
    my $fullurl = shift;
    my ($block, $pathinfo, $api, $qstring) = $self -> get_saved_state();

    # Return url block should never be "login"
    $block = $self -> {"settings"} -> {"config"} -> {"default_block"} if($block eq "login" || !$block);

    # Build the URL from them
    return $self -> build_url("block"    => $block,
                              "pathinfo" => $pathinfo,
                              "api"      => $api,
                              "params"   => $qstring,
                              "fullurl"  => $fullurl);
}


## @method $ build_url(%args)
# Build a url suitable for use at any point in the system. This takes the args
# and attempts to build a url from them. Supported arguments are:
#
# * fullurl  - if set, the resulting URL will include the protocol and host. Defaults to
#              false (URL is absolute from the host root).
# * block    - the name of the block to include in the url. If not set, the current block
#              is used if possible, otherwise the system-wide default block is used.
# * pathinfo - Either a string containing the pathinfo, or a reference to an array
#              containing pathinfo fragments. If not set, the current pathinfo is used.
# * api      - api fragments. If the first element is not "api", it is added.
# * params   - Either a string containing additional query string parameters to add to
#              the URL, or a reference to a hash of additional query string arguments.
#              Values in the hash may be references to arrays, in which case multiple
#              copies of the parameter are added to the query string, one for each
#              value in the array.
# * forcessl - If true, the URL is forced to https: rather than http:
# * anchor   - A string containing the name of the anchor to set in the url
#
# @param args A hash of arguments to use when building the URL.
# @return A string containing the URL.
sub build_url {
    my $self = shift;
    my %args = @_;
    my $base = "";

    # Default the block, item, and API fragments if needed and possible
    $args{"block"} = ($self -> {"cgi"} -> param("block") || $self -> {"settings"} -> {"config"} -> {"default_block"})
        if(!defined($args{"block"}));

    if(!defined($args{"pathinfo"})) {
        my @cgipath = $self -> {"cgi"} -> param("pathinfo");
        $args{"pathinfo"} = \@cgipath if(scalar(@cgipath));
    }

    if(!defined($args{"api"})) {
        my @cgiapi = $self -> {"cgi"} -> param("api");
        $args{"api"} = \@cgiapi if(scalar(@cgiapi));
    }

    # Convert the pathinfo and api to slash-delimited strings
    my $pathinfo = join_complex($args{"pathinfo"}, joinstr => "/");
    my $api      = join_complex($args{"api"}, joinstr => "/");

    # Force the API call to start 'api' if it doesn't
    $api = "api/$api" if($api && $api !~ m|^/?api|);

    # build the query string parameters.
    my $querystring = join_complex($args{"params"}, joinstr => ($args{"joinstr"} || "&amp;"), pairstr => "=", escape => 1);

    # building the URL involves shoving the bits together. path_join is intelligent enough to ignore
    # anything that is undef or "" here, so explicit checks beforehand should not be needed.
    my $url = path_join($self -> {"settings"} -> {"config"} -> {"scriptpath"}, $args{"block"}, $pathinfo, $api);
    $url = path_join($self -> {"settings"} -> {"config"} -> {"httphost"}, $url)
        if($args{"fullurl"});

    # Strip block, pathinfo, and api from the query string if they've somehow made it in there.
    # Note this can't simply be made 'eg' as the progressive match can leave a trailing &
    if($querystring) {
        while($querystring =~ s{((?:&(?:amp;))?)(?:api|block|pathinfo)=[^&]+(&?)}{$1 && $2 ? "&" : ""}e) {}
        $url .= "?$querystring";
    }

    $url =~ s/^http:/https:/
        if($args{"forcessl"} && $url =~ /^http:/);

    $url .= '#'.$args{"anchor"}
        if($args{"anchor"});

    return $url;
}


# ============================================================================
#  Documentation support

## @method $ get_documentation_url($doclink)
# Given a documentation link name, obtain the URL associated with that name.
#
# @param doclink The name of the documentation link to fetch.
# @return The documentation URL if the doclink is valid, undef otherwise.
sub get_documentation_url {
    my $self    = shift;
    my $doclink = shift;

    $self -> clear_error();

    # No point trying anything if there is no link name set.
    return undef if(!$doclink);

    my $urlh = $self -> {"dbh"} -> prepare("SELECT `url`
                                            FROM `".$self -> {"settings"} -> {"database"} -> {"docs"}."`
                                            WHERE `name` LIKE ?");
    $urlh -> execute($doclink)
        or return $self -> self_error("Unable to look up documentation link: ".$self -> {"dbh"} -> errstr);

    # Fetch the url row, and if one has been found return it.
    my $url = $urlh -> fetchrow_arrayref();
    return $url ? $url -> [0] : undef;
}


1;
