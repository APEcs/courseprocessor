## @file
# This file contains the implementation of the HTML Output Handler plugin
# for the course processor.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 3.0
# @date    20 Nov 2010
# @copy    2010, Chris Page &lt;chris@starforge.co.uk&gt;
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# @todo Filtering
# @todo Fix all `### FIXME for v3.7` functions
# @todo Template links in convert_link()

## @class HTMLOutputHandler
# This plugin takes a hierarchy of files stored in the processor intermediate
# format and generates a templated (X)HTML course.
#
package HTMLOutputHandler;

use Cwd qw(getcwd chdir);
use Utils qw(check_directory resolve_path load_file lead_zero);
use strict;

# The location of htmltidy, this must be absolute as we can not rely on path being set.
use constant DEFAULT_TIDY_COMMAND => "/usr/bin/tidy";

# The commandline arguments to pass to htmltidy when cleaning up output.
use constant DEFAULT_TIDY_ARGS    => "-i -w 0 -b -q -c -asxhtml --join-classes no --join-styles no --merge-divs no";

# Should we even bother trying to do the tidy pass?
use constant DEFAULT_TIDY         => 1;


my ($VERSION, $errstr, $htype, $desc);

BEGIN {
	$VERSION       = 3.0;
    $htype         = 'output';                    # handler type - either input or output
    $desc          = 'HTML CBT output processor'; # Human-readable name
	$errstr        = '';                          # global error string
}

# ============================================================================
#  Constructor and identifier functions.  
#   

## @cmethod $ new(%args)
# Create a new plugin object. This will intialise the plugin to a base state suitable
# for use by the processor. The following arguments may be provided to this constructor:
#
# config     (required) A reference to the global configuration object.
# logger     (required) A reference to the global logger object.
# path       (required) The directory containing the processor
# metadata   (required) A reference to the metadata handler object.
# template   (required) A reference to the template engine object.
#
# @param args A hash of arguments to initialise the plugin with. 
# @return A new HTMLInputHandler object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = { @_, };

    # Set defaults in the configuration if values have not been provided.
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidycmd"}   = DEFAULT_TIDY_COMMAND if(!defined($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidycmd"}));
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidyargs"}  = DEFAULT_TIDY_ARGS    if(!defined($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidyargs"}));
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidy"}      = DEFAULT_TIDY         if(!defined($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidy"}));

    return bless $self, $class;
}


## @fn $ get_type()
# Determine the type of handler behaviour this plugin provides. This will always
# return "input" for input plugins, "output" for output plugins, and "reference"
# for reference handler plugins.
#
# @return The plugin type.
sub get_type {
    return $htype
};


## @fn $ get_description()
# Obtain the human-readable descriptive text for this plugin. This will return
# a string that describes the processor in a way that is useful to the user.
#
# @return The handler description
sub get_description {
    return $desc 
};


## @fn $ get_version()
# Obtain the version string for the plugin. This returns a string containing the
# version information for the plugin in a human-readable form.
#
# @return The handler version string.
sub get_version {
    return $VERSION 
};


### FIXME for v3.7
sub process {
    my $self   = shift;

    # kill the reference handler value if the caller has indicated one is not valid.
    if($self -> {"refhandler"} eq "none") {
        $self -> {"refhandler"} = undef;
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "HTMLOutputHandler disabling references processing");
    }

    # Update the template engine to use the handler's templates. This is needed to allow different
    # handlers to use different templates (as input handlers may need to use templates too!)
    $self -> {"template"} -> set_template_dir($self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"});

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing using HTMLOutputHandler");

    # preprocess to get the anchors and terms recorded
    $self -> preprocess($srcdir);

    # Write out the glossary, and possibly reference, pages at this point.
    $self -> write_glossary_pages($srcdir);
    $self -> {"refhandler"} -> write_reference_page($srcdir)
        if($self -> {"refhandler"});

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Preprocessing complete");

    # This should be the top-level "source data" directory, should contain theme dirs
    opendir(SRCDIR, $srcdir)
        or die "FATAL: Unable to open source directory for reading: $!";

    # grab the directory list so we can check it for subdirs, strip .* files though
    my @themes = grep(!/^(\.|CVS)/, readdir(SRCDIR));

    die "FATAL: Unable to locate any themes to parse in $srcdir" if(scalar(@themes) == 0);

    foreach my $theme (@themes) {
        my $fulltheme = "$srcdir/$theme"; # prepend the source directory
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing $theme");

        # if this is a directory, check inside for subdirs ($theme is a theme, subdirs are modules)
        if(-d $fulltheme) {

            # Load the theme metadata
            my $metadata  = $self -> load_metadata($fulltheme);

            if($metadata && ($metadata != 1)) {
                # Get the list of module directories in this theme
                opendir(MODDIR, $fulltheme)
                    or die "FATAL: Unable to open module directory $fulltheme for reading: $!";
                my @modules = grep(!/^(\.|CVS)/, readdir(MODDIR));

                # Process each module.
                foreach my $module (@modules) { 
                    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing $module ($fulltheme/$module)");

                    my $fullmodule = "$fulltheme/$module"; # prepend the module directory...

                    # If this is a module directory, we want to scan it for steps
                    if(-d $fullmodule) {
                        
                        # Scan for steps
                        opendir(SUBDIR, $fullmodule)
                            or die "FATAL: Unable to open subdir for reading: $!";

                        # now grab a list of files we know how to process, then call the internal process
                        # function for each one, remembering to include the full path.
                        my @stepfiles = grep(/^node\d+\.html/, readdir(SUBDIR));
                        
                        if(scalar(@stepfiles)) {
                            my $cwd = getcwd();
                            chdir($fullmodule);

                            my $maxstep = get_maximum_stepid(\@stepfiles);
                            
                            $metadata -> {"module"} -> {$module} -> {"steps"} = { };
                            for(my $i = 0; $i < scalar(@stepfiles); ++$i) {
                                $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing ".$stepfiles[$i]." as ".get_step_name($stepfiles[$i])."... ");
                                my ($previous, $next, $prevlink, $nextlink) = $self -> build_prev_next(\@stepfiles, $i, $metadata -> {"module"} -> {$module} -> {"level"});
                                $self -> process_step($stepfiles[$i], 
                                                      $metadata -> {"module"} -> {$module} -> {"steps"}, 
                                                      $previous, 
                                                      $next,
                                                      get_step_name($stepfiles[0]),
                                                      $prevlink,
                                                      $nextlink,
                                                      get_step_name($stepfiles[scalar(@stepfiles) - 1]),
                                                      $theme,
                                                      $module,
                                                      $include,
                                                      $maxstep,
                                                      $metadata);
                                $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Finished processing $module ($fulltheme/$module)");
                            }
                            chdir($cwd);

                            $self -> cleanup_module($fullmodule, $module);
                        }

                        closedir(SUBDIR);
                    }
                }
                closedir(MODDIR);
                $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing index files");
                $self -> write_theme_indexmap($fulltheme, $theme, $metadata, $include);

            } else { # if($metadata && ($metadata != 1)) {
                $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Skipping directory $fulltheme: no metadata in directory");
            }
        } # if(-d $fulltheme) {
    } # foreach my $theme (@themes) {

    $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "HTMLOutputhandler processing complete");

    $self -> cleanup_lists($srcdir);

    closedir(SRCDIR);

    $self -> write_courseindex($srcdir, $self -> {"fullmap"});
    $self -> framework_merge($srcdir, $frame);

    return 1;
}


# ============================================================================
#  Precheck - can this plugin be applied to the source tree?
#   

## @method $ use_plugin()
# This plugin can always be run against a tree, so we use the use check to ensure that
# the templates are available. This should die if the templates are not avilable, rather
# than return 0.
#
# @return True if the plugin can run against the tree.
sub use_plugin {
    my $self    = shift;

    die "FATAL: HTMLOutputHandler has no template selected.\n" if(!$self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"});

    # prepend the processor template directory if the template is not absolute
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"} = $self -> {"config"} -> {"path"}."/templates/".$self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"} 
        if($self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"} !~ /^\//);

    # Force the path to be absolute in all situations
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"} = resolve_path($self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"});

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "HTMLOutputHandler using template directory : ".$self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"});

    # Make sure the directory actually exists
    check_directory($self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"}, "HTMLOutputHandler template directory");

    # if we get here, we can guarantee to be able to use the plugin.
    return 1;
}


# ============================================================================
#  Utility Code
#   

## @fn $ numeric_order()
# Very simple sort function to ensure that steps are ordered correctly. This will
# support step ids with leading zeros.
#
# @return < 0 if $a is less than $b, 0 if they are the same, >0 if $a is greater than $b. 
sub numeric_order {
    return (0 + $a) <=> (0 + $b);
}


## @fn $ get_step_name($stepid)
# Given a step id, this returns a string containing the canonical filename for the 
# step. Note that this will ensure that the step number is given a leading zero
# if the supplied id is less than 10 and it does not already have a leading zero.
#
# @param stepid The id of the step to generate a filename form.
# @return The step filename in the form 'stepXX.html'
sub get_step_name {
    my $stepid = shift;

    return "step".lead_zero($stepid).".html";
}


## @fn $ get_maximum_stepid($module)
# Obtain the maximum step id in the supplied module. This examines the metadata for
# the specified module to determine the maximum output_id for steps in the module.
# 
# @param module A reference to the module's metadata hash.
# @return The maximum step id in the module, or undef if the module has no steps.
sub get_maximum_stepid {
    my $module = shift;

    # We could try some kind of fancy sort trick here, but frankly anything
    # is going to be slower than a simple scan (potentially O(NlogN) as opposed
    # to O(N)
    my $maxid = 0;
    foreach my $stepid (keys(%{$module -> {"step"}})) {
        $maxid = $module -> {"step"} -> {$stepid} -> {"output_id"} if(defined($module -> {"step"} -> {$stepid} -> {"output_id"}) &&
                                                                      $module -> {"step"} -> {$stepid} -> {"output_id"} > $maxid);
    }
    
    return $maxid || undef;
}


# ============================================================================
#  Tag conversion code.
#  
 
## @method $ convert_term($termname)
# Convert a glossary term marker into a html glossary link. This uses the provided
# term name to derermine which glossary page and anchor to link the user to.
#
# @param termname The name of the term to link to.
# @return A string containing a html link to the appropriate glossary page and entry.
### FIXME for v3.7
sub convert_term {
    my $self = shift;
    my $termname = shift;

    # ensure the term is lowercase
    my $key = lc($termname);

    $key =~ s/[^\w\s]//g; # nuke any non-word/non-space chars
    $key =~ s/\s/_/g;     # replace spaces with underscores.

    # We need the first character of the term for the index link
    my $first = lc(substr($termname, 0, 1));

    # replace the contents of $first for digits and symbols
    if($first =~ /^[a-z]$/) {
        # do nothing...
    } elsif($first =~ /^\d$/) {
        $first = "digit";
    } else {
        $first = "symb";
    }

    # Build and return a glossary link
    return load_complex_template($self -> {"templatebase"}."/theme/module/glossary_link.tem",
                                 { "***letter***" => $first,
                                   "***term***"   => $key,
                                   "***name***"   => $termname });
}


## @method $ convert_image($tagdata)
# Convert an image tag to html markup. This processes the specified list of tag args
# and generates an appropriate html image element, or an error message to include
# in the document.
#
# @param tagdata  The image tag attribute list
# @return The string to replace the image tag with - either a html image element,
#         or an error message.
### FIXME for v3.7
sub convert_image {
    my $self     = shift;
    my $tagdata = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Use if deprecated [image] tag with attributes '$tagdata'"); 

    my %attrs = $tagdata =~ /(\w+)\s*=\s*\"([^\"]+)\"/g;

    # We *NEED* a name, no matter what
    (log_print($Utils::WARNING, $self -> {"verbose"}, "Image tag attribute list does not include name")
         && return "<p class=\"error\">Image tag attribute list does not include name</p>")
        if(!$attrs{"name"});

    # Construct the URL of the image, relative to the module directory
    my $url = "../../images/".$attrs{"name"};

    # Start constructing the styles. The divstyle is needed for alignment issues.
    my $divstyle = "";
    if($attrs{"align"}) {
        if($attrs{"align"} =~ /^left$/i) {
            $divstyle = ' style="clear: left; float: left; margin: 0 0.5em 0.5em 0; position: relative;"';
        } elsif($attrs{"align"} =~ /^right$/i) {        
            $divstyle = ' style="clear: right; float: right; margin: 0 0.5em 0.5em 0; position: relative;"';
        } elsif($attrs{"align"} =~/^center$/i) {
            $divstyle = ' style="width: 100%; text-align: center;"';
        }
    }

    # The image style deals with width, height, and other stuff...
    my $imgstyle = "border: none;";
    $imgstyle .= " width: $attrs{'width'};"   if($attrs{"width"});
    $imgstyle .= " height: $attrs{'height'};" if($attrs{"height"});

    return load_complex_template($self -> {"templatebase"}."/theme/module/image.tem",
                                 {"***name***"     => $url,
                                  "***divstyle***" => $divstyle,
                                  "***imgstyle***" => $imgstyle,
                                  "***alt***"      => $attrs{"alt"} || "",
                                  "***title***"    => $attrs{"title"} || ""});
}


## @method $ convert_anim($tagdata)
# Convert an anim tag to html markup. This processes the specified list of tag args
# and generates the html elements needed to include a flash movie, or an error 
# message to include in the document.
#
# @param tagdata  The anim tag attribute list
# @return The string to replace the animtag with - either a chunk of html,
#         or an error message.
### FIXME for v3.7
sub convert_anim {
    my $self    = shift;
    my $tagdata = shift;

    my %attrs = $tagdata =~ /(\w+)\s*=\s*\"([^\"]+)\"/g;

    # We *NEED* a name, no matter what
    (log_print($Utils::WARNING, $self -> {"verbose"}, "Anim tag attribute list does not include name")
         && return "<p class=\"error\">Anim tag attribute list does not include name</p>")
        if(!$attrs{"name"});

    # As well as width and height
    (log_print($Utils::WARNING, $self -> {"verbose"}, "Anim tag attribute list is missing width or height information")
         && return "<p class=\"error\">Anim tag attribute list is missing width or height information </p>")
        if(!$attrs{"width"} || !$attrs{"height"});
    
    # Construct the URL of the anim, relative to the module directory
    my $url = "../../anims/".$attrs{"name"};

    # Start constructing the styles. The divstyle is needed for alignment issues.
    my $divstyle = "";
    if($attrs{"align"}) {
        if($attrs{"align"} =~ /^left$/i) {
            $divstyle = ' style="clear: left; float: left; margin: 0 0.5em 0.5em 0; position: relative;"';
        } elsif($attrs{"align"} =~ /^right$/i) {        
            $divstyle = ' style="clear: right; float: right; margin: 0 0.5em 0.5em 0; position: relative;"';
        } elsif($attrs{"align"} =~/^center$/i) {
            $divstyle = ' style="width: 100%; text-align: center;"';
        }
    }

    return load_complex_template($self -> {"templatebase"}."/theme/module/anim.tem",
                                 {"***name***"     => $url,
                                  "***divstyle***" => $divstyle,
                                  "***width***"    => $attrs{"width"},
                                  "***height***"   => $attrs{"height"}});
}


## @method $ convert_applet($tagdata)
# Convert an applet tag to html markup. This processes the specified list of tag args
# and generates the html elements needed to include an applet, or an error 
# message to include in the document.
#
# @param tagdata  The applet tag attribute list
# @return The string to replace the applet tag with - either a chunk of html,
#         or an error message.
### FIXME for v3.7
sub convert_applet {
    my $self    = shift;
    my $tagdata = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Use if deprecated [applet] tag with attributes '$tagdata'"); 

    my %attrs = $tagdata =~ /(\w+)\s*=\s*\"([^\"]+)\"/g;

    # We *NEED* a name, no matter what
    (log_print($Utils::WARNING, $self -> {"verbose"}, "Applet tag attribute list does not include name")
         && return "<p class=\"error\">Applet tag attribute list does not include name</p>")
        if(!$attrs{"name"});

    # As well as width and height
    (log_print($Utils::WARNING, $self -> {"verbose"}, "Applet tag attribute list is missing width or height information")
         && return "<p class=\"error\">Applet tag attribute list is missing width or height information </p>")
        if(!$attrs{"width"} || !$attrs{"height"});
    
    # Construct the URL of the anim, relative to the module directory
    my $url = "../../applets/".$attrs{"name"};

    # Start constructing the styles. The divstyle is needed for alignment issues.
    my $divstyle = "";
    if($attrs{"align"}) {
        if($attrs{"align"} =~ /^left$/i) {
            $divstyle = ' style="clear: left; float: left; margin: 0 0.5em 0.5em 0; position: relative;"';
        } elsif($attrs{"align"} =~ /^right$/i) {        
            $divstyle = ' style="clear: right; float: right; margin: 0 0.5em 0.5em 0; position: relative;"';
        } elsif($attrs{"align"} =~/^center$/i) {
            $divstyle = ' style="width: 100%; text-align: center;"';
        }
    }

    return load_complex_template($self -> {"templatebase"}."/theme/module/applet.tem",
                                 {"***name***"     => $url,
                                  "***divstyle***" => $divstyle,
                                  "***width***"    => $attrs{"width"},
                                  "***height***"   => $attrs{"height"},
                                  "***codebase***" => $attrs{"codebase"} || "",
                                  "***archive***"  => $attrs{"archive"} || "",
                                 });
}


## @method $ convert_local($text, $data, $stepid, $lcount, $level, $width, $height)
# Converts a local tag into the appropriate html. This will process the specified
# arguments and data into a popup on the page.
#
# @todo This code currently generates a separate file containing the popup text and
#       generates a html block that opens the file in a popup window. This is 
#       VASTLY less than useful, and should be changed to use div element popups.
#       SEE ALSO: http://www.pat-burt.com/web-development/how-to-do-a-css-popup-without-opening-a-new-window/
# @param text   The text to show in the popup link.
# @param data   The contents of the popup. Should be valid html.
# @param stepid The id of the step the popup occurs in.
# @param lcount The popup count id for this step.
# @param level  The step difficulty level. Must be green, yellow, orange, or red.
# @param width  Optional window width. Defaults to 640.
# @param height Optional window height. Defaults to 480.
# @return The string to replace the local tag with, or an error message.
### FIXME for v3.7
sub convert_local {
    my ($self, $text, $data, $stepid, $lcount, $level, $width, $height) = @_;
  
    $width  = 640 if(!defined($width)  || !$width);
    $height = 480 if(!defined($height) || !$height);

    # convert escaped characters to real ones
    # $data = text_to_html(fix_entities($data));
    $data =~ s/\\\[/\[/g;
    $data =~ s/\\\"/\"/g;
    #$data =~ s/&lt;/</g;
    #$data =~ s/&gt;/>/g;

    open(LOCAL, "> local-$stepid-$lcount.html")
        or die "FATAL: Unable to open local-$stepid-$lcount.html: $!";

    print LOCAL load_complex_template($self -> {"templatebase"}."/theme/module/local.tem",
                                      {"***title***"   => $text,
                                       "***body***"    => $data,
                                       "***include***" => $self -> {"globalheader"},
                                       "***version***" => $self -> {"cbtversion"},
                                       "***level***"   => $level});
    close(LOCAL);

    return load_complex_template($self -> {"templatebase"}."/theme/module/local_link.tem",
                                 {"***text***"   => $text,
                                  "***stepid***" => $stepid,
                                  "***lcount***" => $lcount,
                                  "***width***"  => $width,
                                  "***height***" => $height,
                                 });
}


## @method $ convert_step_tags($content, $stepid, $level)
# Convert any processor markup tags in the supplied step text into the equivalent 
# html. This function scans the provided text for any of the special marker tags
# supported by the processor and replaces them with the appropriate html, using
# the various convert_ functions as needed to support the process.
#
# @param content The step text to process.
# @param stepid  The step's id number.
# @param level   The difficulty level of the step, should be green, yellow, 
#                orange, or red.
# @return The processed step text.
### FIXME for v3.7
sub convert_step_tags {
    my $self    = shift;
    my $content = shift;
    my $stepid  = shift;
    my $level   = shift;
    my $module  = shift;
    my $lcount  = 0;

    # Glossary conversion
    $content =~ s{\[glossary\s+term\s*=\s*"(.*?)"\s*\/\s*\]}{$self->convert_terms($1)}ige;              # [glossary term="" /]
    $content =~ s{\[glossary\s+term\s*=\s*"(.*?)"\s*\].*?\[/glossary\]}{$self->convert_terms($1)}igse;  # [glossary term=""]...[/glossary]

    # Image conversion
    $content =~ s{\[img\s+(.*?)\/?\s*\]}{$self -> convert_image($1)}ige;  # [img name="" width="" height="" alt="" title="" align="left|right|center" /]

    # Anim conversion
    $content =~ s/\[anim\s+(.*?)\/?\s*\]/$self -> convert_anim($1)/ige;   # [anim name="" width="" height="" align="left|right|center" /]

    # Applet conversion
    $content =~ s/\[applet\s+(.*?)\/?\s*\]/$self -> convert_applet_newstyle($1)/ige; # [anim name="" width="" height="" codebase="" archive="" /]

    # clears
    $content =~ s/\[clear\s*\/?\s*\]/<div style="clear: both;"><\/div>/giso; # [clear /]

    # Local conversion
    $content =~ s/\[local\s+text\s*=\s*"(.*?)"\s+width\s*=\s*"(\d+)"\s+height\s*=\s*"(\d+)"\s*\](.*?)\[\/\s*local\s*\]/$self -> convert_local($1, $4, $stepid, ++$lcount, $level, $2, $3)/isge;
    $content =~ s/\[local\s+text\s*=\s*"(.*?)"\s*\](.*?)\[\/\s*local\s*\]/$self -> convert_local($1, $2, $stepid, ++$lcount, $level)/isge;

    # links
    $content =~ s{\[link\s+(?:to|name)\s*=\s*\"(.*?)\"\s*\](.*?)\[/\s*link\s*\]}{$self -> convert_interlink($1, $2, $stepid, $module)}isge; # [link to=""]link text[/link]

    # anchors
    $content =~ s/\[target\s+name\s*=\s*\"(.*?)\"\s*\/?\s*\]/<a name=\"$1\"><\/a>/gis; # [target name="" /]

    # convert references and do any work needed to compress them (eg: converting [1][2][3] to [1,2,3])
    if($self -> {"refhandler"}) {
        $content =~ s/\[ref\s+(.*?)\s*\/?\s*\]/$self -> {"refhandler"} -> convert_references($1)/ige;
        $content = $self -> {"refhandler"} -> compress_references($content);
    }

    return $content;
}


# ============================================================================
#  Interlink handling
#  

## @method void set_anchor_point($name, $theme, $module, $step)
# Record the position of named anchor points. This is the first step in allowing
# user-defined links within the material, in that it records the locations of
# anchor points (similar to anchors in html, but course-wide) so that later 
# code can convert links to those anchors into actual html links. If more than
# one anchor has the same name, the second anchor with the name encountered by
# this function will cause the program to die with a fatal error.
#
# @note This function does not enforce values in theme, module, or step other
#       than requiring that step eiter be undef or in the standard step naming
#       format. theme, module and step /can/ be undef, but having all three be
#       undef makes no sense.
# @param name   The name of the anchor point.
# @param theme  The name of the theme the anchor is in (should be the theme dir name).
# @param module The module the anchor is in (should be the module directory name).
# @param step   The step the anchor is in (should be the step filename).
sub set_anchor_point {
    my ($self, $name, $theme, $module, $step) = @_;

    $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Setting anchor $name in $theme/$module/$step");

    die "FATAL: Redefinition of target $name in $theme/$module/$step, last set in @$args[0]/@$args[1]/@$args[2]\n"
        if($self -> {"anchors"} && $self -> {"anchors"} -> {$name});

    # we're actually only interested in the step number, not the name (which is likely to change anyway)
    $step =~ s/^\D+(\d+(.\d+)?).html?$/$1/ if($step);

    # Record the location
    $self -> {"anchors"} -> {$name} = {"theme"  => $theme, 
                                       "module" => $module, 
                                       "stepid" => $step };
}


## @method $ convert_link($anchor, $text)
# Convert a link to a target into a html hyperlink. This will attempt to locate 
# the anchor specified and create a link to it.
#
# @param anchor The name of the anchor to be linked to.
# @param text   The text to use as the link text.
# @param level  The level at which the link resides. Can be 'theme', or 'step'.
#               If this is not specified, it defaults to 'step'.
# @return A HTML link to the specified anchor, or an error message if the anchor 
#         can not be found.
sub convert_link {
    my $self   = shift;
    my $anchor = shift;
    my $text   = shift;
    my $level  = shift || "step";

    my $targ = $self -> {"anchors"} -> {$anchor};
    if(!$targ) {
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Unable to locate anchor $anchor. Link text is '$text' in $module step $stepid");
        return '<span class="error">'.$text.' (Unable to locate anchor '.$anchor.')</span>';
    }

    my $backup = $level eq "step" ? "../../" : $level eq "theme" ? "../" : die "FATAL: Illegal level specified in convert_link. This should not happen.\n";
    
    return "<a href=\"".$backup.$targ -> {"theme"}."/".$targ -> {"module"}."/step".lead_zero($targ -> {"step"}).".html#$anchor\">$text</a>";
}


# ============================================================================
#  Glossary handling
#  

## @method $ build_glossary_references($level)
# Generate a glossary and references block at a given level in the document. This will
# generate a block with the glossary and references links enabled or disabled depending
# on whether the global glossary and references hashes contain data.
#
# @param level The level to pull the templates from. Should be "", "theme", "theme/module", 
#              "glossary", or "references". DO NOT include a leading slash!
# @return A string containing the glossary and reference navigation block.
sub build_glossary_references {
    my $self       = shift;
    my $level      = shift;

    # construct the filename for the subtemplates
    my $glossary   = ($self -> {"terms"} && scalar(keys(%{$self -> {"terms"}}))) ? "glossary_en" : "glossary_dis";
    my $references = ($self -> {"refs"}  && scalar(keys(%{$self -> {"refs"}}))) ? "references_en" : "references_dis";
    my $name = $glossary."_".$references.".tem";

    # And construct the block
    return $self -> {"template"} -> load_template("$level/glossary_references_block.tem",
                                                  { "***entries***" => $self -> {"template"} -> load_template("$level/$name") });
}  


## @method void set_glossary_point($hashref, $term, $definition, $theme, $module, $step, $title, $storeref)
# Record the glossary definitions or references to glossary definitions in steps. This will 
# store the definition of a glossary term if it has not already been set - if a term has 
# been defined once, attempting to redefine it is a fatal error. If the storeref argument is
# true (or not supplied) the location of the term is stored for later linking from the
# glossary page, if storeref is false, no location information is stored for the glossary 
# page, even for the definition.
#
# @param hashref    A reference to the hash of glossary terms.
# @param term       The term name.
# @param definition The definition of the term. If this is undef or empty, all that is stored
#                   is a reference to the term on the specified page.
# @param theme      The theme name the reference/definition occurs in.
# @param module     The name of the module the reference or definition occurs in.
# @param step       The step file the ref/def occurs in (this should be 'nodeXX.html' or similar)
# @param title      The title of the step, used for presentation purposes.
# @param storeref   If true (the default if not supplied), record the position of the reference
#                   for display in the glossary page. If false, this function does nothing if
#                   the point is a reference. If the point is a definition, and storeref is false,
#                   the definition will be stored but not added to the reference list.
sub set_glossary_point {
    my ($self, $hashref, $term, $definition, $theme, $module, $step, $title, $storeref) = @_;

    # we're actually only interested in the step number, not the name (which is likely to change anyway)
    $step =~ s/^\D+(\d+(.\d+)?).html?$/$1/;
     
    # convert the term to a lowercase, space-converted name 
    my $key = lc($term);
    $key =~ s/[^\w\s]//g; # nuke any non-word/non-space chars
    $key =~ s/\s/_/g;     # replace spaces with underscores.

    # only need to do the redef check if definition is specified
    if($definition) {
        my $args = $hashref -> {$key} -> {"defsource"};

        die "FATAL: Redefinition of term $term in $theme/$module/$step, last set in @$args[0]/@$args[1]/@$args[2]"
            if($args);

        $hashref -> {$key} -> {"term"}       = $term;
        $hashref -> {$key} -> {"definition"} = $definition;
        $hashref -> {$key} -> {"defsource"}  = [$theme, $module, $step, $title];
    }

    $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Setting glossary entry $term in $theme/$module/$step");
    push(@{$hashref -> {$key} -> {"refs"}}, [$theme, $module, $step, $title]) if($storeref);
}


# Construct a single entry in the glossary index. Returns an entry
# based on the the acive and defined status of the specified letter.
### FIXME for v3.7
sub build_glossary_indexentry {
    my $self   = shift;
    my $letter = shift;
    my $link   = shift;
    my $def    = shift;
    my $active = shift;

    if($active) {
        return load_complex_template($self -> {"templatebase"}."/glossary/index-active.tem",
                                     { "***letter***" => uc($letter) });
    } elsif($def && (scalar(@$def) > 0)) {
        return load_complex_template($self -> {"templatebase"}."/glossary/index-indexed.tem",
                                     { "***letter***" => uc($letter),
                                       "***link***" => $link});        
    } else {
        return load_complex_template($self -> {"templatebase"}."/glossary/index-notindexed.tem",
                                     { "***letter***" => uc($letter) });            
    }

}


# Builds the line of letters, number and symbol shown at the top of 
# glossary bodies to allow the user to jump between pages.
### FIXME for v3.7
sub build_glossary_links {
    my $self    = shift;
    my $letter  = shift;
    my $charmap = shift;

    # ensure we always have lowercase letters
    $letter = lc($letter);

    my $index = "";

    # symbols...
    $index .= $self -> build_glossary_indexentry("@", "symb.html", $charmap -> {"symb"}, $letter eq "symb"); 

    # ... then numbers...
    $index .= $self -> build_glossary_indexentry("0-9", "digit.html", $charmap -> {"digit"}, $letter eq "0"); 

    # ... then letters
    foreach my $char ("a".."z") { 
        $index .= $self -> build_glossary_indexentry($char, "$char.html", $charmap -> {$char}, $letter eq $char); 
    }

    return load_complex_template($self -> {"templatebase"}."/glossary/indexline.tem",
                                 { "***entries***" => $index });
}


# Write all the entries for a specified character class to the named
# file.
### FIXME for v3.7
sub write_glossary_file {
    my $self     = shift;
    my $filename = shift;
    my $title    = shift;
    my $letter   = shift;
    my $charmap  = shift;
    my $terms    = $self -> {"terms"};

    # write the file header...
    open(OUTFILE, "> $filename")
        or die "FATAL: Unable to open $filename: $!";

    print OUTFILE load_complex_template($self -> {"templatebase"}."/glossary/header.tem", 
                                        {"***title***"         => $title,
                                         "***include***"       => $self -> {"globalheader"},
                                         "***glosrefblock***"  => $self -> build_glossary_references("glossary"),
                                         "***index***"         => $self -> build_glossary_links($letter, $charmap),
                                         "***breadcrumb***"    => load_complex_template($self -> {"templatebase"}."/glossary/breadcrumb-content.tem",
                                                                                        {"***letter***" => $letter })
                                        });

    # print out the entries for this letter.
    foreach my $term (@{$charmap -> {$letter}}) {
        # convert backlinks
        my $linkrefs = $terms -> {$term} -> {"refs"};
        my $backlinks = "";
        if($linkrefs && scalar(@$linkrefs)) {
            for(my $i = 0; $i < scalar(@$linkrefs); ++$i) {
                my $backlink = $linkrefs -> [$i]; 

                $backlinks .= load_complex_template($self -> {"templatebase"}."/glossary/backlink-divider.tem") if($i > 0);
                $backlinks .= load_complex_template($self -> {"templatebase"}."/glossary/backlink.tem",
                                                    { "***link***" => '../'.$backlink->[0].'/'.$backlink->[1].'/step'.lead_zero($backlink->[2]).'.html',
                                                      "***text***" => ($i + 1) });
            }
        }

        my $key = lc($term);
        $key =~ s/[^\w\s]//g; # nuke any non-word/non-space chars
        $key =~ s/\s/_/g;     # replace spaces with underscores.

        print OUTFILE load_complex_template($self -> {"templatebase"}."/glossary/entry.tem",
                                            { "***termname***"   => $key,
                                              "***term***"       => $terms -> {$term} -> {"term"},
                                              "***definition***" => $terms -> {$term} -> {"definition"},
                                              "***backlinks***"  => $backlinks
                                              });                
    }

    print OUTFILE load_complex_template($self -> {"templatebase"}."/glossary/footer.tem", 
                                        { "***version***"      => $self -> {"cbtversion"} });
    close(OUTFILE);

}


# Write out the glossary pages.
### FIXME for v3.7
sub write_glossary_pages {
    my $self   = shift;
    my $srcdir = shift;
    my $terms  = $self -> {"terms"};

    # do nothing if there are no terms...
    if($terms) {
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing glossary pages");

        # Create the glossary dir if it doesn't currently exist
        mkdir("$srcdir/glossary") unless(-e "$srcdir/glossary");
        
        # get a list of all the terms
        my @termlist = sort(keys(%$terms));

        # calculate which characters are missing and which are available
        my $charmap = {};
        foreach my $term (@termlist) {
            my $letter = lc(substr($term, 0, 1));

            # letters go into individual entries...
            if($letter =~ /^[a-z]$/) {
                push(@{$charmap -> {$letter}}, $term);
                
                # numbers all go together...
            } elsif($letter =~ /^\d$/) {
                push(@{$charmap -> {"digit"}}, $term);
                
                # everything else goes in the symbol group
            } else {
                push(@{$charmap -> {"symb"}}, $term);
            }

        }

        # Process the letters first...
        foreach my $letter ("a".."z") {
            if($charmap -> {$letter} && scalar(@{$charmap -> {$letter}})) {
                $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing $srcdir/glossary/$letter.html");
                $self -> write_glossary_file("$srcdir/glossary/$letter.html",
                                             "Glossary of terms starting with '".uc($letter)."'",
                                             $letter, $charmap);
            }
        }

        # Now numbers...
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing $srcdir/glossary/digit.html");
        $self -> write_glossary_file("$srcdir/glossary/digit.html",
                                     "Glossary of terms starting with digits",
                                     "digit", $charmap);
        
        # ... and everything else
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing $srcdir/glossary/symb.html");
        $self -> write_glossary_file("$srcdir/glossary/symb.html",
                                     "Glossary of terms starting with other characters",
                                     "symb", $charmap);
           
        # Finally, write the index page
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing $srcdir/glossary/index.html");
        open(INDEX, "> $srcdir/glossary/index.html")
            or die "Unable to open glossary index $srcdir/glossary/index.html: $!";
        print INDEX load_complex_template($self -> {"templatebase"}."/glossary/header.tem",
                                          {"***title***"        => "Glossary Index",
                                           "***glosrefblock***" => $self -> build_glossary_references("glossary"),
                                           "***include***"      => $self -> {"globalheader"},
                                           "***index***"        => $self -> build_glossary_links("mu", $charmap),
                                           "***breadcrumb***"   => load_complex_template($self -> {"templatebase"}."/glossary/breadcrumb-indexonly.tem")
                                          });
        print INDEX load_complex_template($self -> {"templatebase"}."/glossary/index-body.tem");
        print INDEX load_complex_template($self -> {"templatebase"}."/glossary/footer.tem");
        close(INDEX);

        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Finished writing glossary pages");
    } else {
        log_print($Utils::WARNING, $self -> {"verbose"}, "No glossary terms to write");
    }

}


# ============================================================================
#  Page interlink and index generation code.
#  

## @method $ build_dependencies($entries, $metadata)
# Construct a string containing the module dependencies seperated by
# the index_dependence delimiter.
#
# @param entries  A reference to an array of module names forming a dependency.
# @param metadata A reference to the theme metadata hash.
# @return A string containing the dependency list.
### FIXME for v3.7
sub build_dependencies {
    my $self     = shift;
    my $entries  = shift;
    my $metadata = shift;
    my $depend   = "";
    
    $entries = [ $entries ] if(!ref($entries)); # make sure we're looking at an arrayref
    my $count = 0;
    foreach my $entry (@$entries) {
        $depend .= load_complex_template($self -> {"templatebase"}."/theme/index_dependency_delimit.tem") if($count > 0);
        $depend .= load_complex_template($self -> {"templatebase"}."/theme/index_dependency.tem",
                                         {"***url***" => "#$entry",
                                          "***title***" => $metadata -> {"module"} -> {$entry} -> {"title"}});
        ++$count;
    }         

    return $depend;
}


## @method void write_theme_indexmap($themedir, $theme, $metadata, $headerinclude)
# Write out the contents of the specified theme's 'themeindex.html' and 'index.html' files.
# This will generate the theme-level text index (containing the list of modules in the 
# theme, their prerequisites and leadstos, and the steps they contain), and the 'cloud map'
# index page. 
#
# @param themedir      The directory containing the theme data.
# @param theme         The theme name as specified in the metadata name element.
# @param metadata      The theme metadata.
# @param headerinclude Any additional data to include in the header, optional.
### FIXME for v3.7
sub write_theme_indexmap {
    my $self     = shift;
    my $themedir = shift;
    my $theme    = shift;
    my $metadata = shift;
    my $headerinclude = shift;

    # Build the main index
    # grab a list of module names, sorted by module order if we have order info or alphabetically if we don't
    my @modnames = sort { die "Attempt to sort module without indexorder while comparing $a and $b" 
                              if(!$metadata -> {"module"} -> {$a} -> {"indexorder"} or !$metadata -> {"module"} -> {$b} -> {"indexorder"});
                          defined($metadata -> {"module"} -> {$a} -> {"indexorder"}) ?
                              $metadata -> {"module"} -> {$a} -> {"indexorder"} <=> $metadata -> {"module"} -> {$b} -> {"indexorder"} :
                              $a cmp $b; }
                        keys(%{$metadata -> {"module"}});

    # For each module, build a list of steps.
    my $body = "";
    foreach my $module (@modnames) {
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Module: $module = ".$metadata -> {"module"} -> {$module} -> {"title"});

        # skip dummy modules
        next if($module eq "dummy" || $metadata -> {"module"} -> {$module} -> {"skip"});

        my ($prereq, $leadsto, $steps) = ("", "", "");

        # build the prerequisites and leadsto links for the module
        # Prerequisites first...
        my $entries = $metadata -> {"module"} -> {$module} -> {"prerequisites"} -> {"target"};
        if($entries) {
            $prereq = load_complex_template($self -> {"templatebase"}."/theme/index_entry_prereqs.tem",,
                                            {"***prereqs***" => $self -> build_dependencies($entries, $metadata)});
        }

        # ... then the leadstos...
        $entries = $metadata -> {"module"} -> {$module} -> {"leadsto"} -> {"target"};
        if($entries) {
            $leadsto = load_complex_template($self -> {"templatebase"}."/theme/index_entry_leadsto.tem",
                                             {"***leadsto***" => $self -> build_dependencies($entries, $metadata)});
        }
        
         # ... and then the steps.
         foreach my $step (sort numeric_order keys(%{$metadata -> {"module"} -> {$module} -> {"steps"}})) {
            $steps .= load_complex_template($self -> {"templatebase"}."/theme/index_step.tem",
                                            {"***url***"   => "$module/".get_step_name($step),
                                             "***title***" => $metadata -> {"module"} -> {$module} -> {"steps"} -> {$step}});
        }

        # finally, glue them all together.
        $body .= load_complex_template($self -> {"templatebase"}."/theme/index_entry.tem",
                                       {"***title***"      => $metadata -> {"module"} -> {$module} -> {"title"},
                                        "***name***"       => $module,
                                        "***level***"      => $metadata -> {"module"} -> {$module} -> {"level"},
                                        "***difficulty***" => ucfirst($metadata -> {"module"} -> {$module} -> {"level"}),
                                        "***prereqs***"    => $prereq,
                                        "***leadsto***"    => $leadsto,
                                        "***steps***"      => $steps});
    }
     
    # dump the index.
    open(INDEX, "> $themedir/themeindex.html")
        or die "FATAL: Unable to open $themedir/themeindex.html for writing: $!";

    print INDEX load_complex_template($self -> {"templatebase"}."/theme/themeindex.tem",
                                      {"***data***"         => $body,
                                       "***title***"        => $metadata -> {"title"},
                                       "***include***"      => $headerinclude,
                                       "***version***"      => $self -> {"cbtversion"},
                                       "***themedrop***"    => $self -> get_map_theme_dropdown($theme, $metadata),
                                       "***glosrefblock***" => $self -> build_glossary_references("theme"),
                                   });
    close(INDEX);


    # Build the theme map page...
    my $mapbody;
    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Building theme map page for".($metadata -> {"title"} || "Unknown theme"));

    # First load any metadata-specified content, if any...
    if($metadata -> {"includes"} -> {"resource"}) {
        my $includes = $metadata -> {"includes"} -> {"resource"};
        $includes = [ $includes ] if(!ref($includes)); # make sure we're looking at an arrayref
        foreach my $include (sort(@$includes)) {
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Including $include");
            
            # if the include is not absolute, prepend the theme directory
            $include = "$themedir/$include" if($include !~ /^\//);

            my $content = load_complex_template($include);
            if($content) {
                $mapbody .= $content;
            } else {
                blargh("Unable to open include file $include: $!");
                $mapbody .= "<p class=\"error\">Unable to open include file $include: $!</p>\n";
            }
        }
    }
    $mapbody = '<p class="error">No body content specified for this theme. Add an <includes> section to the metadata!</p>' if(!$mapbody);

    open(INDEX, "> $themedir/index.html")
        or die "FATAL: Unable to open $themedir/index.html for writing: $!";

    print INDEX load_complex_template($self -> {"templatebase"}."/theme/index.tem",
                                      {"***body***"         => $mapbody,
                                       "***title***"        => $metadata -> {"title"},
                                       "***include***"      => $headerinclude,
                                       "***version***"      => $self -> {"cbtversion"},
                                       "***themedrop***"    => $self -> get_map_theme_dropdown($theme, $metadata),
                                       "***glosrefblock***" => $self -> build_glossary_references("theme"),
                                      });
    close(INDEX);
}


## @method $ build_courseindex_deps($entries, $metadata, $theme)
# Create module dependency entries for the top-level course index. This will
# process the supplied entries into dependency list templates and return the
# composite string.
#
# @param entries  A reference to an array of module names forming a dependency.
# @param metadata A reference to the course-wide composite metadata hash.
# @param theme    The current theme name.
# @return A string containing the dependency list.
### FIXME for v3.7
sub build_courseindex_deps {
    my $self     = shift;
    my $entries  = shift;
    my $metadata = shift;
    my $theme    = shift;
    my $depend   = "";
    
    $entries = [ $entries ] if(!ref($entries)); # make sure we're looking at an arrayref
    my $count = 0;
    foreach my $entry (@$entries) {
        $depend .= load_complex_template($self -> {"templatebase"}."/courseindex-dependency-delimit.tem") if($count > 0);
        $depend .= load_complex_template($self -> {"templatebase"}."/courseindex-dependency.tem",
                                         {"***url***" => "#$theme-$entry",
                                          "***title***" => $metadata -> {$theme} -> {"module"} -> {$entry} -> {"title"}});
        ++$count;
    }         

    return $depend;
}


## @method void write_courseindex($coursedir, $metadata, $headerinclude)
# Write out the course-wide courseindex file. This will generate a full index
# of the whole course, sorted by theme order and module order, and save the
# index to the top-level courseindex.html
#
# @param coursedir The directory into which the index should be written.
# @param metadata  A reference to the course-wide composite metadata hash.
# @param headerinclude Any additional data to include in the header, optional.
### FIXME for v3.7
sub write_courseindex {
    my $self          = shift;
    my $coursedir     = shift;
    my $metadata      = shift;
    my $headerinclude = shift;
    my $body = "";

    # Obtain a sorted list of theme names
    my @themenames = sort { die "Attempt to sort theme without indexorder while comparing $a and $b" 
                                if(!defined($metadata -> {$a} -> {"indexorder"}) or !defined($metadata -> {$b} -> {"indexorder"}));
                            defined($metadata -> {$a} -> {"indexorder"}) ?
                                $metadata -> {$a} -> {"indexorder"} <=> $metadata -> {$b} -> {"indexorder"} :
                                $a cmp $b; 
                          }
                          keys(%$metadata);
    
    
    # Now we can process all the modules in the theme...
    foreach my $theme (@themenames) {

        # grab a list of module names, sorted by module order if we have order info or alphabetically if we don't
        my @modnames = sort { die "Attempt to sort module without indexorder while comparing $a and $b" 
                                  if(!$metadata -> {$theme} -> {"module"} -> {$a} -> {"indexorder"} or !$metadata -> {$theme} -> {"module"} -> {$b} -> {"indexorder"});
                              defined($metadata -> {$theme} -> {"module"} -> {$a} -> {"indexorder"}) ?
                                  $metadata -> {$theme} -> {"module"} -> {$a} -> {"indexorder"} <=> $metadata -> {$theme} -> {"module"} -> {$b} -> {"indexorder"} :
                                  $a cmp $b; 
                            }
                            keys(%{$metadata -> {$theme} -> {"module"}});

        my $modbody = "";

        # For each module, build a list of steps and interlinks.
        foreach my $module (@modnames) {
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Module: $module = ".$metadata -> {$theme} -> {"module"} -> {$module} -> {"title"});

            # skip dummy modules
            next if($module eq "dummy" || $metadata -> {$theme} -> {"module"} -> {$module} -> {"skip"});

            my ($prereq, $leadsto, $steps) = ("", "", "");

            # build the prerequisites and leadsto links for the module
            # Prerequisites first...
            my $entries = $metadata -> {$theme} -> {"module"} -> {$module} -> {"prerequisites"} -> {"target"};
            if($entries) {
                $prereq = load_complex_template($self -> {"templatebase"}."/courseindex-module-prereqs.tem",,
                                                {"***prereqs***" => $self -> build_courseindex_deps($entries, $metadata, $theme)});
            }

            # ... then the leadstos...
            $entries = $metadata -> {$theme} -> {"module"} -> {$module} -> {"leadsto"} -> {"target"};
            if($entries) {
                $leadsto = load_complex_template($self -> {"templatebase"}."/courseindex-module-leadsto.tem",
                                                 {"***leadsto***" => $self -> build_courseindex_deps($entries, $metadata, $theme)});
            }
        
            # ... and then the steps.
            foreach my $step (sort numeric_order keys(%{$metadata -> {$theme} -> {$module} -> {"steps"}})) {
                $steps .= load_complex_template($self -> {"templatebase"}."/courseindex-step.tem",
                                                {"***url***"   => "$theme/$module/".get_step_name($step),
                                                 "***title***" => $metadata -> {$theme} -> {$module} -> {"steps"} -> {$step}});
            }

            # finally, glue them all together.
            $modbody .= load_complex_template($self -> {"templatebase"}."/courseindex-module.tem",
                                              {"***title***"      => $metadata -> {$theme} -> {"module"} -> {$module} -> {"title"},
                                               "***name***"       => "$theme-$module",
                                               "***stepurl***"    => "$theme/$module/step01.html",
                                               "***level***"      => $metadata -> {$theme} -> {"module"} -> {$module} -> {"level"},
                                               "***difficulty***" => ucfirst($metadata -> {$theme} -> {"module"} -> {$module} -> {"level"}),
                                               "***prereqs***"    => $prereq,
                                               "***leadsto***"    => $leadsto,
                                               "***steps***"      => $steps});
        } # foreach my $module (@modnames) {
        
        # Shove the module into a theme...
        $body .= load_complex_template($self -> {"templatebase"}."/courseindex-theme.tem",
                                       {"***name***"    => $theme,
                                        "***title***"   => $metadata -> {$theme} -> {"title"},
                                        "***modules***" => $modbody});
    } # foreach $theme (@themenames) {

    # dump the index.
    open(INDEX, "> $coursedir/courseindex.html")
        or die "FATAL: Unable to open $coursedir/courseindex.html for writing: $!";

    print INDEX load_complex_template($self -> {"templatebase"}."/courseindex.tem",
                                      {"***body***"         => $body,
                                       "***title***"        => "Course index",
                                       "***include***"      => $headerinclude,
                                       "***version***"      => $self -> {"cbtversion"},
                                       "***glosrefblock***" => $self -> build_glossary_references(""),
                                   });
    close(INDEX);
}


# Construct the next and previous fragments based on the current
# position within the module.
### FIXME for v3.7
sub build_prev_next {
    my $self    = shift;
    my $steps   = shift;
    my $current = shift;
    my $level   = shift;
    my ($previous, $next, $prevlink, $nextlink);
    
    if($current > 0) {
        $previous = load_complex_template($self -> {"templatebase"}."/theme/module/previous_enabled.tem",
                                          {"***prevlink***" => get_step_name(@$steps[$current - 1]),
                                           "***level***"    => $level});
        $prevlink = load_complex_template($self -> {"templatebase"}."/theme/module/link_prevstep.tem",
                                          {"***prevstep***" => get_step_name(@$steps[$current - 1])});
    } else {
        $previous = load_complex_template($self -> {"templatebase"}."/theme/module/previous_disabled.tem",
                                          {"***level***"    => $level});
        $prevlink = "";
    }

    if($current < (scalar(@$steps) - 1)) {
        $next     = load_complex_template($self -> {"templatebase"}."/theme/module/next_enabled.tem",
                                          {"***nextlink***" => get_step_name(@$steps[$current + 1]),
                                           "***level***"    => $level});
        $nextlink = load_complex_template($self -> {"templatebase"}."/theme/module/link_nextstep.tem",
                                          {"***nextstep***" => get_step_name(@$steps[$current + 1])});
    } else {
        $next     = load_complex_template($self -> {"templatebase"}."/theme/module/next_disabled.tem",
                                          {"***level***"    => $level});
        $nextlink = "";
    }

    return ($previous, $next, $prevlink, $nextlink);
}


# returns true if the named module appears in the arrayref provided. Returns
# false otherwise. If the first argument is not an arrayref, it is coerced 
# into one. Used to determine whether the named module is a prerequisite or
# leadsto of another module.
### FIXME for v3.7
sub is_related {
    my $entries = shift;
    my $check   = shift;

    return 0 if (!$entries); # do nothing if there are no entries

    $entries = [ $entries ] if(!ref($entries)); # makes sure this is an arrayref

    # return true if the name we are supposed to check appears in the list
    foreach my $entry (@$entries) {
        return 1 if($entry eq $check);
    }

    return 0;
}



# ============================================================================
#  Dropdown handling
#  

## @method $ build_theme_dropdowns()
# Generate the theme dropdowns shown on theme map and theme index pages, and included
# in each step nav menu. This generates two partially-processed dropdown menus, and
# get_theme_dropdown() should be called to complete the processing before inserting 
# into the target template. $self -> {"dropdowns"} -> {"theme_themeview"} stores the
# theme level dropdown, while $self -> {"dropdowns"} -> {"theme_stepview"} stores 
# the equivalent step dropdown.
# 
# @note This will die if any theme is missing its indexorder (although the metadata
#       validation should have failed if it does not!)
# @return A reference to an array of theme names, sorted by index order.
sub build_theme_dropdowns {
    my $self = shift;

    # These accumulate the bodies of the dropdowns, and will be shoved into templated
    # containers before storing.
    my $themedrop_theme  = ""; # dropdown menu shown in theme index/maps
    my $themedrop_module = ""; # theme dropdown in modules 
    
    # Generate a sorted list of the themes stored in the metadata
    my @themenames = sort { die "Attempt to sort theme without indexorder while comparing $a and $b" 
                                if(!defined($self -> {"mdata"} -> {"themes"} -> {$a} -> {"theme"} -> {"indexorder"}) or !defined($self -> {"mdata"} -> {"themes"} -> {$b} -> {"theme"} -> {"indexorder"}));
                            
                            return $self -> {"mdata"} -> {"themes"} -> {$a} -> {"theme"} -> {"indexorder"} <=> $self -> {"mdata"} -> {"themes"} -> {$b} -> {"theme"} -> {"indexorder"};
                          }
                          keys(%$self -> {"mdata"} -> {"themes"});

    # Build the ordered list of themes for both levels.
    foreach $theme (@themenames) {
        $themedrop_theme  .= $self -> {"template"} -> load_template("theme/themedrop-entry.tem",
                                                                    { "***name***"  => $theme,
                                                                      "***title***" => $layout -> {$theme} -> {"title"}});

        $themedrop_module .= $self -> {"template"} -> load_template("theme/module/themedrop-entry.tem",
                                                                    { "***name***"  => $theme,
                                                                      "***title***" => $layout -> {$theme} -> {"title"}});
    }

    # Put the accumulated dropdowns into containers and store for later.
    # themes_themeview is the list of themes visible when viewing a theme map, or theme index.
    $self -> {"dropdowns"} -> {"themes_themeview"}  = $self -> {"template"} -> load_template("theme/themedrop.tem",
                                                                                             { "***entries***" => $themedrop_theme });

    # themes_stepview is the list of themes visible when viewing a step.
    $self -> {"dropdowns"} -> {"themes_stepview"}   = $self -> {"template"} -> load_template("theme/module/themedrop.tem",
                                                                                             { "***entries***" => $themedrop_module });

    return \@themenames;
}


## @method void build_step_dropdowns($theme, $module)
# Generate the step dropdown for the specified module. This generates the partially
# processed step dropdown for the specified module in the provided theme, and 
# get_step_dropdown() should be called to complete the processing prior to inserting
# into the target template.
#
# @note This will die if called on a module that contains no steps.
sub build_step_dropdowns {
    my $self   = shift;
    my $theme  = shift;
    my $module = shift;

    my $stepdrop = "";

    # Process the list of steps for this module, sorted by numeric order. Steps are stored using a numeric
    # step id (not 'nodeXX.html' as they were in < 3.7)
    foreach my $step (sort numeric_order keys(%{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {$module} -> {"step"}})) {
        # Skip steps with no output id
        next if(!$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {$module} -> {"step"} -> {$step} -> {"output_id"});

        $stepdrop .= $self -> {"template"} -> load_template("theme/module/stepdrop-entry.tem",
                                                            { "***name***"  => get_step_name($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {$module} -> {"step"} -> {$step} -> {"output_id"}),
                                                              "***title***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {$module} -> {"steps"} -> {$step} -> {"title"}});
    }
     
    die "FATAL: No steps stored for \{$theme\} -> \{$module\} -> \{steps\}\n" if(!$stepdrop);

    # and store the partially-processed dropdown
    $self -> {"dropdowns"} -> {$theme} -> {$module} -> {"steps"} = $self -> {"template"} -> load_template("theme/module/stepdrop.tem",
                                                                                                          {"***entries***" => $stepdrop });
}


## @method void build_module_dropdowns($theme)
# Generate the completed module dropdowns for each module in the specified theme, and
# the partially processed dropdowns for the steps in each module. 
#
# @note This will die if any module is missing its indexorder (although this should
#       not happen if the metadata was validated during loading)
sub build_module_dropdowns {
    my $self  = shift;
    my $theme = shift;

    my @modulenames =  sort { die "Attempt to sort module without indexorder while comparing $a and $b" 
                                  if(!$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"} or !$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$b} -> {"indexorder"});
                                  
                              return $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"} <=> $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$b} -> {"indexorder"} :
                            }
                            keys(%{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"}});

    foreach my $module (@modulenames) {
        my $moduledrop = "";
            
        # first create the module dropdown for this module (ie: show all modules in this theme and how they relate)
        foreach my $buildmod (@modulenames) {
            my $relationship = "";
                
            # first determine whether buildmod is a prerequisite, leadsto or the current module
            if($buildmod eq $module) {
                $relationship = "-current";
            } elsif(is_related($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"prerequisites"} -> {"target"}, $buildmod)) {
                $relationship = "-prereq";
            } elsif(is_related($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"leadsto"} -> {"target"}, $buildmod)) {
                $relationship = "-leadsto";
            } 

            $moduledrop .= $self -> {"template"} -> load_template("theme/module/moduledrop-entry".$relationship.".tem",
                                                                  { "***level***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$buildmod} -> {"level"},
                                                                    "***title***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$buildmod} -> {"title"},
                                                                    "***name***"  => $buildmod });
        }

        # store the generated menu for this module
        $self -> {"dropdowns"} -> {$theme} -> {$module} -> {"modules"} = $self -> {"template"} -> load_template("theme/module/moduledrop.tem",
                                                                                                                {"***entries***" => $moduledrop });

        # Now build the step dropdowns
        $self -> build_step_dropdowns($theme, $module);
    } # foreach my $module (@modulenames)
}


## @method void build_dropdowns()
# Builds the menus that will replace dropdown markers in the templates during processing. 
# This should be called as part of the preprocessing work as the menus must have been built 
# before any pages can be generated.
sub build_dropdowns {
    my $self = shift;

    # Construct the easy dropdowns first.
    my $themenames = $self -> build_theme_dropdowns();
    
    # Now build up the step level module and step menus
    foreach $theme (@$themenames) {
        $self -> build_module_dropdowns($theme);
    }
}


# returns a string containing the theme dropdown menu with the current theme 
# marked. The menu produced is suitable for use in steps.
### FIXME for v3.7
sub get_step_theme_dropdown {
    my $self     = shift;
    my $theme    = shift;
    my $metadata = shift;

    # Load the chunk that needs to be located in the dropdown
    my $anchor = load_complex_template($self -> {"templatebase"}."theme/module/themedrop-entry.tem",
                                       { "***name***" => $theme,
                                         "***title***" => $metadata -> {"title"}});
                                       
    # And the chunk that should replace the bit above
    my $replace = load_complex_template($self -> {"templatebase"}."theme/module/themedrop-entry-current.tem",
                                       { "***current***" => ' class="current"',
                                         "***name***"    => $theme,
                                         "***title***"   => $metadata -> {"title"}});
 
    die "FATAL: Unable to open anchor template themedrop-entry.tem: $!"  if(!$anchor);
    die "FATAL: Unable to open replace template themedrop-entry.tem: $!" if(!$replace);

    # copy the theme dropdown so we can wrangle it
    my $dropdown = $self -> {"dropdowns"} -> {"themes_module"};

    # replace the current theme
    $dropdown =~ s/\Q$anchor\E/$replace/;

    # now nuke the remainder of the current tags
    $dropdown =~ s/\*\*\*current\*\*\*//g;

    return $dropdown;
}


# returns a string containing the theme dropdown menu with the current theme 
# marked. The menu produced is suitable for use in theme maps.
### FIXME for v3.7
sub get_map_theme_dropdown {
    my $self     = shift;
    my $theme    = shift;
    my $metadata = shift;

    # Load the chunk that needs to be located in the dropdown
    my $anchor = load_complex_template($self -> {"templatebase"}."/theme/themedrop-entry.tem",
                                       { "***name***" => $theme,
                                         "***title***" => $metadata -> {"title"}});
                                       
    # And the chunk that should replace the bit above
    my $replace = load_complex_template($self -> {"templatebase"}."/theme/themedrop-entry-current.tem",
                                       { "***current***" => ' class="current"',
                                         "***name***"    => $theme,
                                         "***title***"   => $metadata -> {"title"}});

    die "FATAL: Unable to open anchor template themedrop_entry.tem: $!"  if(!$anchor);
    die "FATAL: Unable to open replace template themedrop_entry.tem: $!" if(!$replace);

    # copy the theme dropdown so we can wrangle it
    my $dropdown = $self -> {"dropdowns"} -> {"themes_theme"};

    # replace the current theme
    $dropdown =~ s/\Q$anchor\E/$replace/;

    # now nuke the remainder of the current tags
    $dropdown =~ s/\*\*\*current\*\*\*//g;

    return $dropdown;
}


# Obtain a string for the step dropdown, marking the current step so it can be 
# inserted into the step body.
### FIXME for v3.7
sub get_step_dropdown {
    my $self   = shift;
    my $theme  = shift;
    my $module = shift;
    my $step   = shift;
    my $title  = shift;

    # set up a chunk to use as an anchor in the menu
    my $anchor = load_complex_template($self -> {"templatebase"}."/theme/module/stepdrop-entry.tem",
                                       { "***name***" => get_step_name($step),
                                         "***title***" => $title });

    # this chunk will replace the above
    my $replace = load_complex_template($self -> {"templatebase"}."/theme/module/stepdrop-entry.tem",
                                        { "***current***" => ' class="current"',
                                          "***name***"    => get_step_name($step),
                                          "***title***"   => $title });
    
    die "FATAL: Unable to open anchor template stepdrop-entry.tem: $!"  if(!$anchor);
    die "FATAL: Unable to open replace template stepdrop-entry.tem: $!" if(!$replace);

    # Create a copy of the step dropdown so it can be modified
    my $dropdown = $self -> {"dropdowns"} -> {$theme} -> {$module} -> {"steps"};

    # replace the current step
    $dropdown =~ s/\Q$anchor\E/$replace/;
    
    # and nuke the remainder of the current markers
    $dropdown =~ s/\*\*\*current\*\*\*//g;

    return $dropdown;
}


# ============================================================================
#  Cleanup code.
#  

### FIXME for v3.7
sub cleanup_module {
    my $self = shift;
    my $moddir = shift;
    my $modname = shift;

    `rm -f $moddir/node*.html` unless($self -> {"debug"});
}


### FIXME for v3.7
sub cleanup_lists {
    my $self   = shift;
    my $srcdir = shift;
    
    `rm -f $srcdir/animlist.txt`;
    `rm -f $srcdir/imagelist.txt`;
    `rm -f $srcdir/appletlist.txt`;    
    `rm -f $srcdir/version.txt`;    
}


# ============================================================================
#  Postprocess
#

## @method void framework_template($source, $dest, $template)
# Attempt to template a top-level framework file. This will attempt to load and
# parse the contents of the specified framework file, and if it can extract the
# required data (title and 'real' body) it will save the data to dest using the
# specified template. If the required data can not be parsed from the file, this
# simply copies source to dest.
#
# @param source   The file to be processed.
# @param dest     The name of the file to write the processed data to.
# @param template The template to use when generating the output file, if possible.
### FIXME for v3.7
sub framework_template {
    my ($self, $source, $dest, $template) = @_;

    # First load the source file and extract the gubbins we're interested in
    open(SOURCE, $source)
        or die "FATAL: Unable to open top-level source file $source: $!";

    undef $/;
    my $sourcedata = <SOURCE>;
    $/ = "\n";

    close(SOURCE);

    my ($title, $content) = $sourcedata =~ m{<title>(.*?)</title>.*<div\s+id="content">(.*?)</div>\s*<!-- id="content" -->}iso;

    if($title && $content) {  
        open(DEST, "> $dest")
            or die "FATAL: Unable to save top-level file $dest: $!";
        
        print DEST load_complex_template($self -> {"templatebase"}."/$template",
                                         {"***title***"         => $title,
                                          "***body***"          => $content,
                                          "***version***"       => $self -> {"cbtversion"},
                                          "***glosrefblock***"  => $self -> build_glossary_references(""),
                                      });

        close(DEST);
    } else {
        blargh("HTMLOutputhandler::framework_template(): Unable to locate required sections in $source, falling back on copy");
        `cp $source $dest`;
    }

}


## @method void framework_merge($outdir, $framedir)
# Merge the framework directory into the output, rewriting the content into the
# templates as needed.
#
# @param outdir   The directory to write the templated framework files to.
# @param franedir The framework directory to read data from.
### FIXME for v3.7
sub framework_merge {
    my ($self, $outdir, $framedir) = @_;

    opendir(FRAME, $framedir)
        or die "FATAL: Unable to open framework directory: $!";

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Merging framework at $framedir to $outdir...");

    while(my $entry = readdir(FRAME)) {
        next if($entry =~ /^\./);

        # if the entry is a directory then we want to simply copy it (NOTE: This behaviour depends
        # on the framework html files being in the top level of the tree. Were this is not the case
        # then far more advanced path handling would be required in generating the templated pages.
        # Unless there is a /blindingly/ good reason, I suggest avoiding changing this setup!)
        if(-d "$framedir/$entry") {
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Copying directory $framedir/$entry and its contents to $outdir...");
            my $out = `cp -rv $framedir/$entry $outdir`;
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "cp output is:\n$out");
        
        # process html files
        } elsif($entry =~ /\.html?$/) {
            my ($name) = $entry =~ /^(.*?)\.html?$/;
            die "FATAL: HTMLOutputhandler::framework_merge(): unable to get name from $entry!" if(!$name);
            
            # First, if a template exists with the same name as the file, use it
            if(-e $self -> {"templatebase"}."/$name.tem") {
                $self -> framework_template("$framedir/$entry", "$outdir/$entry", "$name.tem");

            # Handle popups...
            } elsif($entry =~ /_popup.html?$/) {
                $self -> framework_template("$framedir/$entry", "$outdir/$entry", "popup.tem");

            # Otherwise pass through the standard template
            } else {
                $self -> framework_template("$framedir/$entry", "$outdir/$entry", "global.tem");
            }
        # otherwise just straight-copy the file, as we don't know what to do with it
        } else {
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Copying $framedir/$entry to $outdir...");
            my $out = `cp -rv $framedir/$entry $outdir`;
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "cp output is: $out");
        }   
    }

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Merge complete.");

    closedir(FRAME);

}


# ============================================================================
#  Core processing code.
#  

## @method void preprocess()
# Scan the document tree recording the location of anchors and glossary terms 
# in the course content. This will go through the course data loading and validating
# the metadata as needed, recording where anchors, terms (and, if needed, references)
# appear in the material. Once this completes the HTMLOutputhandler object will have
# three hashes containing glossary term locations, reference locations, and the 
# validated metadata for the course and all themes. The preprocess also counts how
# many steps there are in the whole course for progress updates later.
#
# @note The preprocess almost completely ignores filtering, and it will store metadata,
#       glossary definitions (but not references) and reference definitions (but not 
#       references to them) even if a theme, module, or step they occur in is filtered
#       out of the final course. This is necessary because the definition of a term may
#       only be present in a resource that will be filtered out, but references to it
#       may exist elsewhere in the course. It should be noted that link anchors *will not*
#       be stored if the resource will be excluded.
sub preprocess {
    my $self = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Starting preprocesss");

    # A bunch of references to hashes built up as preprocessing proceeds.
    $self -> {"terms"} = { } if(!defined($self -> {"terms"}));
    $self -> {"refs"}  = { } if(!defined($self -> {"refs"}));

    # And a counter to keep track of how many files need processing
    $self -> {"stepcount"} = 0;

    # Load the course metadata here. We don't need it, but it'll be useful later.
    $self -> {"mdata"} = $self -> {"metadata"} -> load_metadata($self -> {"config"} -> {"Processor"} -> {"outputdir"}, 1);
    die "FATAL: Unable to load course metadata.\n"
        if(!defined($self -> {"mdata"} -> {"course"}) || ref($self -> {"mdata"} -> {"course"}) ne "HASH");
    
    # This should be the top-level "source data" directory, and it should contain theme dirs
    opendir(SRCDIR, $self -> {"config"} -> {"Processor"} -> {"outputdir"})
        or die "FATAL: Unable to open source directory for reading: $!";

    # grab the directory list so we can check it for subdirs, strip .* files though
    my @themes = grep(!/^(\.|CVS)/, readdir(SRCDIR));
    foreach my $theme (@themes) {
        my $fulltheme = path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, $theme); # prepend the source directory

        # if this is a directory, check inside for subdirs ($entry is a theme, subdirs are modules)
        if(-d $fulltheme) {
            # load the metadata if possible
            my $metadata = $self -> {"metadata"} -> load_metadata($fulltheme, 1);

            # skip directories without metadata, or non-theme metadata
            next if($metadata == 1 || !$metadata -> {"theme"});

            $self -> {"mdata"} -> {"themes"} -> {$theme} = $metadata; # otherwise, store it.

            # Determine whether this theme will actually end up in the generated course
            my $exclude_theme = $self -> {"filter"} -> exclude_resource($metadata -> {"theme"});

            # Now we need to get a list of modules inside the theme. This looks at the list of modules 
            # stored in the metadata so that we don't need to worry about non-module directoried...
            foreach my $module (keys(%{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"module"}})) {
                my $fullmodule = path_join($fulltheme, $module); # prepend the module directory...

                # Determine whether the module will be included in the course (it will always be
                # excluded if the theme is excluded)
                my $exclude_module = $exclude_theme || $self -> {"filter"} -> exclude_resource($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module});

                # If this is a module directory, we want to scan it for steps
                if(-d $fullmodule) {
                    opendir(SUBDIR, $fullmodule)
                        or die "FATAL: Unable to open module directory for reading: $!";
            
                    # Know grab a list of files we know how to process, then call the internal process
                    # function for each one, remembering to include the full path.
                    my @steps = grep(/^node\d+\.html/, readdir(SUBDIR));
            
                    if(scalar(@steps)) {
                        my $cwd = getcwd();
                        chdir($fullmodule);

                        my $outstep = 0;
                        foreach my $step (@steps) {
                            my ($stepid) = $step =~ /$node0?(\d+).html/;

                            # If we have a step entry in the metadata, check whether this step will be excluded
                            # (it will be excluded if the module is, or the step is listed in the metadata and
                            # is excluded)
                            my $exclude_step = $exclude_module ||
                                ($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} &&
                                 $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$stepid} &&
                                 $self -> {"filter"} -> exclude_resource($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$stepid}));

                            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Preprocessing $fullmodule/$step... ");

                            my $content = load_file($step)
                                or die "FATAL: Unable to open $fullmodule/$step: $!";

                            my ($title) = $content =~ m{<title>\s*(.*?)\s*</title>}im;

                            # Record the locations of any anchors in the course
                            if(!$exclude_step) {
                                pos($content) = 0;
                                while($content =~ /\[target\s+name\s*=\s*\"([-\w]+)\"\s*\/?\s*\]/isg) {
                                    $self -> set_anchor_point($1, $theme, $module, $step);
                                }
                            }

                            # reset so we can scan for glossary terms
                            pos($content) = 0; 
                            # first look for definitions...
                            while($content =~ m{\[glossary\s+term\s*=\s*\"([^\"]+?)\"\s*\](.*?)\[\/glossary\]}isg) {
                                $self -> set_glossary_point($self -> {"terms"}, $1, $2, $theme, $module, $step, $title, !$exclude_step);
                            }

                            # Now look for references to the terms...
                            pos($content) = 0; 
                            while($content =~ m{\[glossary\s+term\s*=\s*\"([^\"]+?)\"\s*\/\s*\]}isg) {
                                $self -> set_glossary_point($self -> {"terms"}, $1, undef, $theme, $module, $step, $title, !$exclude_step);
                            }

                            # Next look for references if the reference handler is valid.
                            if($self -> {"refhandler"}) {
                                pos($content) = 0; 
                                while($content =~ m{\[ref\s+(.*?)\s*/?\s*\]}isg) {
                                    $self -> {"refhandler"} -> set_reference_point($self -> {"refs"}, $1, $theme, $module, $step, $title, !$exclude_step);
                                }
                            }

                            # record the step details for later generation steps, if necessary
                            if(!$exclude_step) {
                                $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Recording $title step as $theme -> $module -> steps -> $step");
                                $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {$module} -> {"step"} -> {$stepid} -> {"title"}     = $title;
                                $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {$module} -> {"step"} -> {$stepid} -> {"output_id"} = lead_zero(++$outstep);

                                # Increment the step count for later progress display
                                ++$self -> {"stepcount"};
                            }

                            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Done preprocessing $fullmodule/$step");                               
                        }
                        chdir($cwd);
                    } # if(scalar(@steps))

                    closedir(SUBDIR);
                } # if(-d $fullmodule)
            } # foreach my $module (@modules) 
            closedir(MODDIR);
        } # if(-d $fulltheme)
    } # foreach my $theme (@themes)

    closedir(SRCDIR);
    
    $self -> build_dropdowns();

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Finished preprocesss");
}


### FIXME for v3.7
sub process_step {
    my $self      = shift;
    my $filename  = shift;
    my $indexdata = shift;
    my $previous  = shift;
    my $next      = shift;
    my $firststep = shift;
    my $prevlink  = shift;
    my $nextlink  = shift;
    my $laststep  = shift;
    my $theme     = shift;
    my $module    = shift;
    my $include   = shift;
    my $maxstep   = shift;
    my $metadata  = shift;
    
    # grab the step ID from the filename
    my ($stepid) = $filename =~ /^\D+(\d+(.\d+)?).html?$/;

    # load the entire file so we can parse it
    open(STEP, $filename)
        or die "FATAL: Unable to open $filename: $!";
    
    undef $/;
    my $content = <STEP>;
    $/= "\n";
    close(STEP);
    
    # extract the bits we're interested in...
    my ($title, $body);
    ($title) = $content =~ /<title>\s*(.*?)\s*<\/title>/si;
    ($body ) = $content =~ /<body.*?>\s*(.*?)\s*(<hr>)?\s*<\/body>/si;

    die "FATAL: Unable to read body from $filename" if(!$body);

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Obtained body for step $filename, title is $title. Processing body.");

    # Strip inline title
    $body =~ s/<h\d><a name=".*?">.*?<\/a>\s*<\/h\d>//si;
    
    # convert local node links to step links
    $body =~ s/node(\d+).html/"step".$1.".html"/ge;

    # convert latex references to local images
    $body =~ s{file:/usr/lib/latex2html/icons/crossref.png}{../../images/crossref.png}gi;

    # back-convert escaped links
    $body =~ s/&lt;a\s+href="(.*?)"\s*&gt;/<a href="$1">/gi;
    $body =~ s/&lt;\/a&gt;/<\/a>/gi;

    # Store the title for step
    $indexdata -> {get_step_name($filename)} = $title;

    # tag conversion
    $body = $self -> convert_step_tags($body, $stepid, $metadata -> {"module"} -> {$module} -> {"level"}, $module);

    # build an uppercase version of the level name for presentation
    my $difficulty = ucfirst($metadata -> {"module"} -> {$module} -> {"level"});

    # Save the step back...
    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing out processed data to ".get_step_name($filename));
    open(STEP, "> ".get_step_name($filename))
        or die "FATAL: Unable to open $filename: $!";
       
    print STEP load_complex_template($self -> {"templatebase"}."/theme/module/step.tem",
                                     {"***title***"         => $title,
                                      "***body***"          => $body,
                                      "***previous***"      => $previous,
                                      "***next***"          => $next,
                                      "***startlink***"     => load_complex_template($self -> {"templatebase"}."/theme/module/link_firststep.tem", { "***firststep***" => $firststep }),
                                      "***lastlink***"      => load_complex_template($self -> {"templatebase"}."/theme/module/link_laststep.tem",  { "***laststep***"  => $laststep  }),
                                      "***prevlink***"      => $prevlink,
                                      "***nextlink***"      => $nextlink,
                                      "***level***"         => $metadata -> {"module"} -> {$module} -> {"level"},
                                      "***difficulty***"    => $difficulty,
                                      "***themename***"     => $metadata -> {"title"},
                                      "***themeurl***"      => $metadata -> {"../index.html"},
                                      "***modulename***"    => $metadata -> {"module"} -> {$module} -> {"title"},
                                      "***version***"       => $self -> {"cbtversion"},
                                      "***include***"       => $include,
                                      "***stepnumber***"    => $stepid,
                                      "***stepmax***"       => $maxstep,
                                      "***glosrefblock***"  => $self -> build_glossary_references("theme/module"),
                                      "***themedrop***"     => $self -> get_step_theme_dropdown($theme, $metadata),
                                      "***moduledrop***"    => $self -> {"dropdowns"} -> {$theme} ->  {$module} -> {"modules"} || "<!-- No module dropdown! -->",
                                      "***stepdrop***"      => $self -> get_step_dropdown($theme, $module, $filename, $metadata) || "<!-- No step dropdown! -->" ,
                                      })
        or die "FATAL: Unable to write to ".get_step_name($filename).", possible cause: $@";

    close(STEP);

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing complete");

    # Try to do tidying if the tidy mode has been specified and it exists
    if($self -> {"tidy"}) {
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Tidying ".get_step_name($filename));
        if(-e $tidybin) {
            my $name = get_step_name($filename);

            # make a backup if we're running in debug mode
            `cp -f $name $name.orig` if($self -> {"debug"});

            # Now invoke tidy
            my $cmd = "$tidybin $tidyopts -m $name";
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Invoing $cmd");
            my $out = `$cmd 2>&1`;
            print $out if($self -> {"verbose"} > 1);            
        } else {
            blargh("Unable to run htmltidy: $tidybin does not exist");
        }
    }
    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Step processing complete");
}





1;
