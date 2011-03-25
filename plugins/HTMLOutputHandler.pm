## @file
# This file contains the implementation of the HTML Output Handler plugin
# for the course processor.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 3.1
# @date    8 March 2011
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

## @class HTMLOutputHandler
# This plugin takes a hierarchy of files stored in the processor intermediate
# format and generates a templated (X)HTML course.
#
package HTMLOutputHandler;

use strict;
use base qw(Plugin); # This class extends Plugin

use Cwd qw(getcwd chdir);
use File::Path qw(make_path);
use ImageTools;
use MIME::Base64;
use URI::Encode qw(uri_encode);
use Utils qw(check_directory resolve_path load_file save_file lead_zero path_join);


# The location of htmltidy, this must be absolute as we can not rely on path being set.
use constant DEFAULT_TIDY_COMMAND => "/usr/bin/tidy";

# The commandline arguments to pass to htmltidy when cleaning up output.
use constant DEFAULT_TIDY_ARGS    => "-i -w 0 -b -q -c -asxhtml --join-classes no --join-styles no --merge-divs no --merge-spans no";

# Should backups be made before steps are tidied?
use constant DEFAULT_BACKUP       => 0;

# Should we even bother trying to do the tidy pass?
use constant DEFAULT_TIDY         => 1;

# Plugin basic information
use constant PLUG_TYPE            => 'output';
use constant PLUG_DESCRIPTION     => 'HTML output processor';


# ============================================================================
#  Plugin class override functions
#   

## @cmethod $ new(%args)
# Overridded plugin creator. This will create a new Plugin object, and then set
# HTMLInputHandler-specific values in the new object.
#
# @param args A hash of arguments to pass to the Plugin creator.
# @return A new HTMLInputHandler object.
sub new {
    my $invocant = shift;
    my $class    = ref($invocant) || $invocant;
    my $self     = $class -> SUPER::new(@_);

    # Set the plugin-specific data
    $self -> {"htype"}       = PLUG_TYPE;
    $self -> {"description"} = PLUG_DESCRIPTION;
    
    # Do we have any options specified on the command line?
    if($self -> {"config"} -> {"Processor"} -> {"outargs"}) {
        # If we have an arrayref, join it into a string (each element of the arrayref could contain
        # multiple args, so we can't assume each element can be parsed as-is)
        my $argtemp = join(',', @{$self -> {"config"} -> {"Processor"} -> {"outargs"}});

        # Now split it up on our terms, and shove into the config
        my @args = split(/,/, $argtemp);
        foreach my $arg (@args) {
            # split the arg up, if possible
            my ($key, $val) = $arg =~ /^(\w+)\s*:\s*(.*)$/;
            
            # Store it if we have something
            $self -> {"config"} -> {"HTMLOutputHandler"} -> {$key} = $val if($key && $val);
        }
    }

    # Set defaults in the configuration if values have not been provided.
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidycmd"}    = DEFAULT_TIDY_COMMAND if(!defined($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidycmd"}));
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidyargs"}   = DEFAULT_TIDY_ARGS    if(!defined($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidyargs"}));
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidybackup"} = DEFAULT_BACKUP       if(!defined($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidybackup"}));
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidy"}       = DEFAULT_TIDY         if(!defined($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidy"}));

    $self -> {"imagetools"} = new ImageTools(template => $self -> {"template"});

    return $self;
}


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
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"} = path_join($self -> {"path"},"templates",$self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"}) 
        if($self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"} !~ /^\//);

    # Force the path to be absolute in all situations
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"} = resolve_path($self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"});

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "HTMLOutputHandler using template directory : ".$self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"});

    # Make sure the directory actually exists
    check_directory($self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"}, "HTMLOutputHandler template directory");

    # if we get here, we can guarantee to be able to use the plugin.
    return 1;
}


## @method $ process()
# Run the plugin over the contents of the course data. This will process all 
# intermediate files in the course directory into a templated xhtml course cbt.
sub process {
    my $self   = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing course using HTMLOutputHandler.");

    # kill the reference handler value unless the caller has indicated one is valid.
    if(!$self -> {"refhandler"} || $self -> {"refhandler"} eq "none") {
        $self -> {"refhandler"} = undef;
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "HTMLOutputHandler disabling centralised references processing.");
    }

    # Update the template engine to use the handler's templates. This is needed to allow different
    # handlers to use different templates (as input handlers may need to use templates too!)
    $self -> {"template"} -> set_template_dir($self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"});

    # preprocess to get the anchors and terms recorded
    $self -> preprocess();

    # Write out the glossary, and possibly reference, pages at this point.
    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing glossary and reference files.");
    $self -> write_glossary_pages();
    $self -> {"refhandler"} -> write_reference_page()
        if($self -> {"refhandler"});

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing themes.");

    # Display progress if needed...
    $self -> {"progress"} = ProgressBar -> new(maxvalue => $self -> {"stepcount"},
                                               message  => "HTMLOutputHandler processing html files...")
        if(!$self -> {"config"} -> {"Processor"} -> {"quiet"} && $self -> {"config"} -> {"Processor"} -> {"verbosity"} == 0);
    my $processed = 0;

    # Go through each theme defined in the metadata, processing its contents into 
    # the output format.
    foreach my $theme (keys(%{$self -> {"mdata"} -> {"themes"}})) {
        my $fulltheme = path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, $theme);

        # Skip themes that should not be included
        if($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"exclude_resource"}) {
            $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Theme $theme excluded by filtering rules.");

            # Nuke skipped content from the destination.
            `$self->{config}->{paths}->{rm} -rf $fulltheme` unless($self -> {"config"} -> {"Processor"} -> {"debug"});
            next;
        }

        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing theme $theme.");

        # Confirm that the theme is a directory, and check inside for subdirs ($theme is a theme, subdirs are modules)
        if(-d $fulltheme) {

            # Now we need to get a list of modules inside the theme. This looks at the list of modules 
            # stored in the metadata so that we don't need to worry about non-module directoried...
            foreach my $module (keys(%{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"}})) {
                my $fullmodule = path_join($fulltheme, $module); # prepend the module directory...

                # Determine whether the module will be included in the course
                if($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"exclude_resource"}) {
                    $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Module $theme excluded by filtering rules.");

                    # Nuke skipped content from the destination
                    `$self->{config}->{paths}->{rm} -rf $fullmodule` unless($self -> {"config"} -> {"Processor"} -> {"debug"});
                    next;
                }

                $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing $module ($fulltheme/$module).");

                # If this is a module directory, we want to scan it for steps
                if(-d $fullmodule) {
                    my $cwd = getcwd();
                    chdir($fullmodule);

                    # Determine what the maximum step id in the module is
                    my $maxstep = get_maximum_stepid($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module});
                            
                    # Process each step stored in the metadata
                    foreach my $stepid (keys(%{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"}})) {
                        
                        # Step exclusion has already been determined by the preprocessor, so we can just check that
                        if(!$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$stepid} -> {"output_id"}) {
                            $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Step $stepid excluded by filtering rules.");

                            my $nukename = path_join($fullmodule, "node".lead_zero($stepid).".html");
                            `$self->{config}->{paths}->{rm} -f $nukename` unless($self -> {"config"} -> {"Processor"} -> {"debug"});
                            
                            next;
                        }

                        $self -> process_step($theme, $module, $stepid, $maxstep);

                        # Update the progress bar if needed
                        $self -> {"progress"} -> update(++$processed) if($self -> {"progress"});
                    }
                    chdir($cwd);

                    $self -> cleanup_module($fullmodule);
                    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Finished processing $module ($fulltheme/$module).");

                } # if(-d $fullmodule) 
            } # foreach my $module (keys(%{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"}}))

            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing theme index files.");
            $self -> write_theme_index($theme);
            $self -> write_theme_textindex($theme);

        } else { # if(-d $fulltheme) 
            # Seriously, this should never happen, unless the filesystem has been changed under the processor -
            # the only way we can actually get to check this theme is if metadata has been loaded for it, which
            # can't happen if the theme directory does not exist.
            die "FATAL: Attempt to access non-existent directory $fulltheme. This should not happen.\n";
        }

        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing $theme.");
    } # foreach my $theme (@themes) 

    # We need a newline after the progress bar if it is enabled.
    print "\n" if($self -> {"progress"});

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing course index files.");
    $self -> write_course_index();
    $self -> write_course_textindex();
    $self -> write_course_frontpage();

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Merging template framework.");
    $self -> framework_merge();

    # Last stage is to remove all unnecessary media from the media directory.
    $self -> cleanup_media();

    # show any tidy output messages
    print "Tidy output messages follow:\n".$self -> {"tidyout"} if($self -> {"tidyout"});

    # All done...
    $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "HTMLOutputhandler processing complete");

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


## @fn $ step_sort()
# Sort function used to ensure that intermediate format steps are sorted in ascending
# numeric order.
#
# @return < 0 if $a is less than $b, 0 if they are the same, >0 if $a is greater than $b. 
sub step_sort {
    my ($aid) = $a =~ /^node0?(\d+).html?$/;
    my ($bid) = $b =~ /^node0?(\d+).html?$/;

    return $aid <=> $bid;
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


## @method $ get_extrahead($level)
# Obtain the extra header block set for the course, with any {COURSE_BASE} markers
# replaced with an appropriate path back to the base of the course.
#
# @param level The level at which the page this should be inserted at will be. Must
#              be one of "step", "theme", "glossary", "references", "course".
# @return The extra header string to include in the page head element.
sub get_extrahead {
    my $self  = shift;
    my $level = shift;

    my $extra = $self -> {"mdata"} -> {"course"} -> {"extrahead"} || "";

    # don't bother doing anything if we have nothing set
    return $extra if(!$extra);

    # work out any prefix we need.
    my $backup;
    if($level eq "step") {
        $backup = "../../" 
    } elsif ($level eq "theme" || $level eq "glossary" || $level eq "resources") {
        $backup = "../"; 
    } elsif($level eq "course") {
        $backup = "";
    } else {
        die "FATAL Illegal level $level specified in get_extrahead. This should not happen.\n";
    }

    # Replace the base marker as needed
    $extra =~ s|\{COURSE_BASE\}/|$backup|g;

    return $extra;
}


# ============================================================================
#  Interlink handling
#  

## @method void set_anchor_point($name, $theme, $module, $stepid)
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
# @param stepid The id of step the anchor is in.
sub set_anchor_point {
    my ($self, $name, $theme, $module, $stepid) = @_;

    $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Setting anchor $name in $theme/$module/$stepid");

    die "FATAL: Redefinition of target $name in $theme/$module/$stepid, last set in ".$self -> {"anchors"} -> {$name} -> {"theme"}."/".
                                                                                      $self -> {"anchors"} -> {$name} -> {"module"}."/".
                                                                                      $self -> {"anchors"} -> {$name} -> {"stepid"}."\n"
        if($self -> {"anchors"} && $self -> {"anchors"} -> {$name});

    # Record the location
    $self -> {"anchors"} -> {$name} = {"theme"  => $theme, 
                                       "module" => $module, 
                                       "stepid" => $stepid};
}


## @method $ convert_link($anchor, $text, $level)
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
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Unable to locate anchor $anchor. Link text is '$text'.");
        return '<span class="error">'.$text.' (Unable to locate anchor '.$anchor.')</span>';
    }

    my $backup = $level eq "step" ? "../../" : $level eq "theme" ? "../" : die "FATAL: Illegal level specified in convert_link. This should not happen.\n";
    
    return $self -> {"template"} -> load_template("theme/module/link.tem",
                                                  {"***backup***" => $backup,
                                                   "***theme***"  => $targ -> {"theme"},
                                                   "***module***" => $targ -> {"module"},
                                                   "***step***"   => get_step_name($targ -> {"stepid"}),
                                                   "***anchor***" => $anchor,
                                                   "***text***"   => $text});
}


# ============================================================================
#  Glossary handling
#  

## @fn $ cleanup_term_name($term)
# Given a term name, convert it into a format suitable for using in html links.
# This will ensure that the term is in lowercase, removes any spaces, and encodes
# any non-word characters.
#
# @param term The term to convert to a safe format.
# @return The converted term.
sub cleanup_term_name {
    my $term = shift;

    # convert the term to a lowercase, space-converted name 
    my $key = lc($term);
    $key =~ s/\s/_/g;     # replace spaces with underscores.

    # And URL-encode any unsafe characters (including reserved).
    return uri_encode($key, 1);
}


## @method $ build_glossary_references($level)
# Generate a glossary and references block at a given level in the document. This will
# generate a block with the glossary and references links enabled or disabled depending
# on whether the global glossary and references hashes contain data.
#
# @param level The level to pull the templates from. Should be "course", "theme", "module", 
#              "glossary", or "references".
# @return A string containing the glossary and reference navigation block.
sub build_glossary_references {
    my $self       = shift;
    my $level      = shift;
    
    $level = "" if($level eq "course");
    $level = "theme/" if($level eq "theme");
    $level = "theme/module/" if($level eq "module");

    # construct the filename for the subtemplates
    my $glossary   = ($self -> {"terms"} && scalar(keys(%{$self -> {"terms"}}))) ? "glossary_en" : "glossary_dis";
    my $references = ($self -> {"refs"}  && scalar(keys(%{$self -> {"refs"}}))) ? "references_en" : "references_dis";
    my $name = $glossary."_".$references.".tem";

    # And construct the block
    return $self -> {"template"} -> load_template($level."glossary_references_block.tem",
                                                  { "***entries***" => $self -> {"template"} -> load_template($level."$name") });
}  


## @method void set_glossary_point($term, $definition, $theme, $module, $step, $title, $storeref)
# Record the glossary definitions or references to glossary definitions in steps. This will 
# store the definition of a glossary term if it has not already been set - if a term has 
# been defined once, attempting to redefine it is a fatal error. If the storeref argument is
# true (or not supplied) the location of the term is stored for later linking from the
# glossary page, if storeref is false, no location information is stored for the glossary 
# page, even for the definition.
#
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
    my ($self, $term, $definition, $theme, $module, $step, $title, $storeref) = @_;

    # we're actually only interested in the step number, not the name (which is likely to change anyway)
    $step =~ s/^\D+(\d+(.\d+)?).html?$/$1/;
     
    # convert the term to a lowercase, space-converted name 
    my $key = cleanup_term_name($term);

    # only need to do the redef check if definition is specified
    if($definition) {
        my $args = $self -> {"terms"} -> {$key} -> {"defsource"};

        die "FATAL: Redefinition of term $term in $theme/$module/$step, last set in @$args[0]/@$args[1]/@$args[2]"
            if($args);

        $self -> {"terms"} -> {$key} -> {"term"}       = $term;
        $self -> {"terms"} -> {$key} -> {"definition"} = $definition;
        $self -> {"terms"} -> {$key} -> {"defsource"}  = [$theme, $module, $step, $title];
    }

    $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Setting glossary entry $term in $theme/$module/$step");
    push(@{$self -> {"terms"} -> {$key} -> {"refs"}}, [$theme, $module, $step, $title]) if($storeref);
}


## @method $ convert_glossary_term($termname)
# Convert a glossary term marker into a html glossary link. This uses the provided
# term name to derermine which glossary page and anchor to link the user to.
#
# @param termname The name of the term to link to.
# @return A string containing a html link to the appropriate glossary page and entry.
sub convert_glossary_term {
    my $self     = shift;
    my $termname = shift;

    # Ensure the term is lowercase
    my $key = cleanup_term_name($termname);

    # We need the first character of the term for the index link
    my $first = lc(substr($termname, 0, 1));

    # Replace the contents of $first for digits and symbols
    if($first =~ /^[a-z]$/) {
        # do nothing...
    } elsif($first =~ /^\d$/) {
        $first = "digit";
    } else {
        $first = "symb";
    }

    # Build and return a glossary link
    return $self -> {"template"} -> load_template("theme/module/glossary_link.tem",
                                                  { "***letter***" => $first,
                                                    "***term***"   => $key,
                                                    "***name***"   => $termname });
}


## @method $ build_glossary_indexentry($letter, $link, $entries, $active)
# Construct a single entry in the glossary index. Returns an entry
# based on the the acive and defined status of the specified letter.
#
# @param letter  The letter to generate the index entry for.
# @param link    The link to the page for the letter.
# @param entries A reference to an array of terms starting with the letter, or undef
#                if no entries start with that letter.
# @param active  True if the entry for this letter is currently active, false otherwise.
# @return A string containing the index entry for the letter.
sub build_glossary_indexentry {
    my $self    = shift;
    my $letter  = shift;
    my $link    = shift;
    my $entries = shift;
    my $active  = shift;

    if($active) {
        return $self -> {"template"} -> load_template("glossary/index-active.tem"    , { "***letter***" => uc($letter) });
    } elsif($entries && (scalar(@$entries) > 0)) {
        return $self -> {"template"} -> load_template("glossary/index-indexed.tem"   , { "***letter***" => uc($letter),
                                                                                         "***link***"   => $link});
    } else {
        return $self -> {"template"} -> load_template("glossary/index-notindexed.tem", { "***letter***" => uc($letter) });
    }

}


## @method $ build_glossary_indexbar($letter, $charmap)
# Builds the line of letters, number and symbol shown at the top of glossary pages
# to allow the user to jump between pages.
#
# @param letter  The letter of the page the indexbar will appear on. Should be "" for
#                the overall index, 'a' to 'z', 'digit', or 'symb'
# @param charmap A reference to a hash of character to term lists.
# @return A string containing the glossary index bar.
sub build_glossary_indexbar {
    my $self    = shift;
    my $letter  = shift;
    my $charmap = shift;

    # ensure we always have lowercase letters
    $letter = lc($letter);

    my $index = "";

    # symbols...
    $index .= $self -> build_glossary_indexentry("@", "symb.html", $charmap -> {"symb"}, $letter eq "symb"); 

    # ... then numbers...
    $index .= $self -> build_glossary_indexentry("0-9", "digit.html", $charmap -> {"digit"}, $letter eq "digit"); 

    # ... then letters
    foreach my $char ("a".."z") { 
        $index .= $self -> build_glossary_indexentry($char, "$char.html", $charmap -> {$char}, $letter eq $char); 
    }

    return $self -> {"template"} -> load_template("glossary/indexline.tem", { "***entries***" => $index });
}


## @method void write_glossary_file($filename, $title, $letter, $charmap)
# Write all the entries for a specified character class to the named file. This will
# generate a glossary page for all terms starting with the specified letter, and
# write it to the file.
#
# @param filename The name of the file to write the page to.
# @param title    The title of the page.
# @param letter   The letter that all terms on the page should start with, either a 
#                 lowercase alphabetic character, 'digit', or 'symb'.
# @param charmap  A reference to a hash of character to term lists.
sub write_glossary_file {
    my $self     = shift;
    my $filename = shift;
    my $title    = shift;
    my $letter   = shift;
    my $charmap  = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing glossary page '$filename'");

    # Generate the entries for this letter.
    my $entries = "";
    foreach my $term (@{$charmap -> {$letter}}) {
        # convert backlinks
        my $linkrefs = $self -> {"terms"} -> {$term} -> {"refs"};
        my $backlinks = "";

        # Only generate the entry if we have one or more references to the term (this is necessary
        # as a term may be defined in a filtered step, but never referenced from the rest of the
        # course, and we don't want to include definitions of terms that don't appear in the 
        # generated material at all)
        if($linkrefs && scalar(@$linkrefs)) {
            for(my $i = 0; $i < scalar(@$linkrefs); ++$i) {
                my $backlink = $linkrefs -> [$i]; 

                $backlinks .= $self -> {"template"} -> load_template("glossary/backlink-divider.tem") if($i > 0);
                $backlinks .= $self -> {"template"} -> load_template("glossary/backlink.tem",
                                                                     { "***link***" => '../'.$backlink->[0].'/'.$backlink->[1].'/step'.lead_zero($backlink->[2]).'.html',
                                                                       "***text***" => ($i + 1) });
            }

            $entries .= $self -> {"template"} -> load_template("glossary/entry.tem",
                                                               { "***termname***"   => cleanup_term_name($term),
                                                                 "***term***"       => $self -> {"terms"} -> {$term} -> {"term"},
                                                                 "***definition***" => $self -> {"terms"} -> {$term} -> {"definition"},
                                                                 "***backlinks***"  => $backlinks
                                                               });
        }
    } # foreach my $term (@{$charmap -> {$letter}})

    # Save the page out.
    save_file($filename, 
              $self -> {"template"} -> load_template("glossary/entrypage.tem",
                                                     {"***title***"        => $title,
                                                      "***glosrefblock***" => $self -> build_glossary_references("glossary"),
                                                      "***include***"      => $self -> get_extrahead("glossary"),
                                                      "***index***"        => $self -> build_glossary_indexbar($letter, $charmap),
                                                      "***breadcrumb***"   => $self -> {"template"} -> load_template("glossary/breadcrumb-content.tem",
                                                                                                                     {"***letter***" => $letter }),
                                                      "***version***"      => $self -> {"mdata"} -> {"course"} -> {"version"},
                                                      "***entries***"      => $entries,
                                                     }));
}


## @method void write_glossary_pages()
# Generate the glossary pages, and an index page for the glossary. This will create
# glossary pages (one page per alphabetic character, one for digits, one for symbols)
# and an index page providing links to the term pages.
sub write_glossary_pages {
    my $self   = shift;

    # Only do anything if we have any terms defined.
    if(!$self -> {"terms"}) {
        $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "No glossary terms to write");
        return;
    }
        
    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing glossary pages.");

    my $outdir = path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, "glossary");

    # Create the glossary dir if it doesn't currently exist
    if(!-d $outdir) {
        mkdir $outdir
            or die "FATAL: Unable to create glossary directory: $!\n";
    }   
    
    # get a list of all the terms
    my @termlist = sort(keys(%{$self -> {"terms"}}));

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
        $self -> write_glossary_file(path_join($outdir, "$letter.html"), "Glossary of terms starting with '".uc($letter)."'", $letter, $charmap)
            if($charmap -> {$letter} && scalar(@{$charmap -> {$letter}}));
    }

    # Now numbers...
    $self -> write_glossary_file(path_join($outdir, "digit.html"), "Glossary of terms starting with digits", "digit", $charmap);
    
    # ... and everything else
    $self -> write_glossary_file(path_join($outdir, "symb.html"), "Glossary of terms starting with other characters", "symb", $charmap);
    
    # Finally, we need the index page
    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing index.html");

    # Create the content of the page
    save_file(path_join($outdir, "index.html"), $self -> {"template"} -> load_template("glossary/indexpage.tem",
                                                                                       {"***glosrefblock***" => $self -> build_glossary_references("glossary"),
                                                                                        "***include***"      => $self -> get_extrahead("glossary"),
                                                                                        "***index***"        => $self -> build_glossary_indexbar("", $charmap),
                                                                                        "***breadcrumb***"   => $self -> {"template"} -> load_template("glossary/breadcrumb-indexonly.tem"),
                                                                                        "***version***"      => $self -> {"mdata"} -> {"course"} -> {"version"},
                                                                                       }));

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Finished writing glossary pages");
}


# ============================================================================
#  Page interlink and index generation code.
#  

## @method $ build_navlinks($stepid, $maxstep, $level)
# Construct the navigation link fragments based on the current position within 
# the module. This creates the steps based on the rule that 1 <= $stepid <= $maxstep
# and the steps are continuous. As of the changes introduced in 3.7 this can be
# guaranteed in all courses, regardless of the scheme used by the author.
#
# @param stepid  The current step id number.
# @param maxstep The maximum stepid in the module.
# @param level   The module difficulty level ('green', 'yellow', etc)
# @return A reference to a hash containing the next and previous button and link
#         fragments.
sub build_navlinks {
    my $self      = shift;
    my $stepid    = shift;
    my $maxstep   = shift;
    my $level     = shift;
    my $fragments = {};
    
    if($stepid > 1) {
        $fragments -> {"button"} -> {"previous"} = $self -> {"template"} -> load_template("theme/module/previous_enabled.tem",
                                                                                          {"***prevlink***" => get_step_name($stepid - 1),
                                                                                           "***level***"    => $level});

        $fragments -> {"link"} -> {"previous"}   = $self -> {"template"} -> load_template("theme/module/link_prevstep.tem",
                                                                                          {"***prevstep***" => get_step_name($stepid - 1)});
    } else {
        $fragments -> {"button"} -> {"previous"} = $self -> {"template"} -> load_template("theme/module/previous_disabled.tem",
                                                                                          {"***level***"    => $level});
        $fragments -> {"link"} -> {"previous"}   = "";
    }

    if($stepid < $maxstep) {
        $fragments -> {"button"} -> {"next"}     = $self -> {"template"} -> load_template("theme/module/next_enabled.tem",
                                                                                          {"***nextlink***" => get_step_name($stepid + 1),
                                                                                           "***level***"    => $level});
        $fragments -> {"link"} -> {"next"}       = $self -> {"template"} -> load_template("theme/module/link_nextstep.tem",
                                                                                          {"***nextstep***" => get_step_name($stepid + 1)});
    } else {
        $fragments -> {"button"} -> {"next"}     = $self -> {"template"} -> load_template("theme/module/next_disabled.tem",
                                                                                          {"***level***"    => $level});
        $fragments -> {"link"} -> {"next"}       = "";
    }

    $fragments -> {"link"} -> {"first"} = $self -> {"template"} -> load_template("theme/module/link_firststep.tem", { "***firststep***" => get_step_name(1) });
    $fragments -> {"link"}  -> {"last"} = $self -> {"template"} -> load_template("theme/module/link_laststep.tem" , { "***laststep***"  => get_step_name($maxstep) });

    return $fragments;
}


## @method $ build_dependencies($theme, $module, $level, $mode)
# Generate the dependency list for the specified module in the specified theme. This will
# create a list of prerequisites or leadstos for the specified theme, based on the value
# specified in the mode argument. It may be used to generate theme or course level index
# dependency lists by setting level to the required value.
#
# @param theme  The theme the index is being generated for.
# @param module The module to generate the dependency list for.
# @param level  The level the list is being generated for, should be "course" or "theme".
# @param mode   The dependency mode, should be "prerequisites" or "leadsto"
# @return A string containing the dependency list.
sub build_dependencies {
    my $self    = shift;
    my $theme   = shift;
    my $module  = shift;
    my $level   = shift;
    my $mode    = shift;

    my $entries = "";
    my $prefix  = ($level eq "course" ? "" : "theme/");

    # Ensure that we have a hash for the specified mode, and it has targets.
    if($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {$mode} &&
       $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {$mode} -> {"target"}) {
        foreach my $entry (sort @{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {$mode} -> {"target"}}) {
            # Skip targets that are not included
            next if($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$entry} -> {"exclude_resource"});
            
            $entries .= $self -> {"template"} -> load_template("index_dependency_delimit.tem") if($entries);
            $entries .= $self -> {"template"} -> load_template("index_dependency.tem",
                                                               {"***url***"   => "#$entry",
                                                                "***title***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$entry} -> {"title"}});
        }         
    }

    return $self -> {"template"} -> load_template("index_entry_".$mode.".tem", {"***entries***" => $entries});
}


## @method $ build_index_modules($theme, $level)
# Generate the text index of modules and steps inside the specified theme, ordered by 
# the indexorder set for each module. This will generate the index body used in the 
# write_theme_textindex() and write_course_textindex() functions.
#
# @param theme The theme the index should be generated for.
# @param leve  The level the index is being generated for, should be "course" or "theme".
# @return A string containing the theme index body.
sub build_index_modules {
    my $self  = shift;
    my $theme = shift;
    my $level = shift;

    my $prefix      = ($level eq "course" ? "" : "theme/");
    my $themeprefix = ($level eq "course" ? $theme : ""); 

    # grab a list of module names, sorted by module order if we have order info or alphabetically if we don't
    my @modnames =  sort { die "Attempt to sort module without indexorder while comparing $a and $b"
                               if(!$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"} or !$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$b} -> {"indexorder"});

                           return $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"} <=> $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$b} -> {"indexorder"};
                         }
                         keys(%{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"}});

    # For each module, build a list of steps.
    my $body = "";
    foreach my $module (@modnames) {
        # skip modules that won't be included in the course
        next if($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"exclude_resource"});

        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing index entry for module ".$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"title"});

        # Build the list of steps in the module.
        my $steps = "";
        foreach my $stepid (sort numeric_order keys(%{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"}})) {
            # Skip steps that should not be included
            next if(!$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$stepid} -> {"output_id"});

            $steps .= $self -> {"template"} -> load_template($prefix."index_step.tem",
                                                             {"***url***"   => path_join($themeprefix, $module, get_step_name($stepid)),
                                                              "***title***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$stepid} -> {"title"}});
        }

        # Generate the entry for the module.
        $body .= $self -> {"template"} -> load_template($prefix."index_entry.tem",
                                                        {"***name***"       => $module,
                                                         "***stepurl***"    => path_join($themeprefix, $module, get_step_name(1)),
                                                         "***title***"      => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"title"},
                                                         "***level***"      => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"level"},
                                                         "***difficulty***" => ucfirst($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"level"}),
                                                         "***prereqs***"    => $self -> build_dependencies($theme, $module, $level, "prerequisites"),
                                                         "***leadsto***"    => $self -> build_dependencies($theme, $module, $level, "leadsto"),
                                                         "***steps***"      => $steps});
    }

    return $body;
}


## @method void write_theme_textindex($theme)
# Writes out the text-only index file for the course. This will go through each module in the
# course in index order, and generate the list of steps and the prerequisites and leadstos the
# module has.
#
# @param theme The name of the theme to generate the index for.
sub write_theme_textindex {
    my $self  = shift;
    my $theme = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Building theme index page for ".$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"title"});

    # Write the index.
    save_file(path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, $theme, "themeindex.html"),
              $self -> {"template"} -> load_template("theme/themeindex.tem",
                                                     {# Basic content
                                                      "***data***"         => $self -> build_index_modules($theme, "theme"),
                                                      "***title***"        => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"title"},

                                                      # Dropdown in the menu bar
                                                      "***themedrop***"    => $self -> get_theme_dropdown($theme, "theme"),

                                                      # Standard stuff
                                                      "***glosrefblock***"  => $self -> build_glossary_references("theme"),
                                                      "***include***"       => $self -> get_extrahead("theme"),
                                                      "***version***"       => $self -> {"mdata"} -> {"course"} -> {"version"},
                                                     }));
}


## @method void write_theme_index($theme)
# Write out the contents of the specified theme's 'index.html' file. This will 
# generate the theme-level text index page using the data in the theme's includes
# or, if no includes are set, an auto-generate theme map.
#
# @note As of the current version of this tool, auto-generation of theme maps is
#       not done, and themes must include the appropriate includes and resources
#       in their metadata.
#
# @param theme    The theme name as specified in the metadata name element.
sub write_theme_index {
    my $self     = shift;
    my $theme    = shift;
    my $body;

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Building theme map page for ".$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"title"});

    # Do we have any resources for this theme map? If so, see whether they should be included
    if($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"includes"} &&
       $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"includes"} -> {"resource"} &&
       scalar($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"includes"} -> {"resource"})) {

        foreach my $resource (@{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"includes"} -> {"resource"}}) {
            # Skip resources that should not be included
            if(!$self -> {"filter"} -> includes_filter($resource)) {
                $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Resource ".substr((ref($resource) eq "HASH" ? $resource -> {"content"} : $resource), 0, 16)."... excluded by filter rule");
                next;
            }

            # The resource is being included, so add its contents to the map body
            $body .= (ref($resource) eq "HASH" ? $resource -> {"content"} || "Empty theme map specified!" : $resource);
        }
    } else {
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Attempt to use autogenerated theme map. Not implemented yet. Set up resources!");
    }

    # FIXME: Replace this with a call to the automatic map generator in 3.8!
    $body = '<p class="error">No body content specified for this theme. Add an <includes> section to the metadata!</p>' if(!$body);

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Scanning index for media file use.");
    $self -> scan_step_media($body);

    # Write the index.
    save_file(path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, $theme, "index.html"),
              $self -> {"template"} -> load_template("theme/index.tem",
                                                     {# Basic content
                                                      "***body***"         => $body,
                                                      "***title***"        => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"title"},

                                                      # Dropdown in the menu bar
                                                      "***themedrop***"    => $self -> get_theme_dropdown($theme, "theme"),

                                                      # Standard stuff
                                                      "***glosrefblock***"  => $self -> build_glossary_references("theme"),
                                                      "***include***"       => $self -> get_extrahead("theme"),
                                                      "***version***"       => $self -> {"mdata"} -> {"course"} -> {"version"},
                                                     }));

}


## @method void write_course_textindex()
# Write out the course-wide courseindex file. This will generate a full index
# of the whole course, sorted by theme order and module order, and save the
# index to the top-level courseindex.html
sub write_course_textindex {
    my $self = shift;

    # Obtain a sorted list of theme names
    my @themenames = sort { die "Attempt to sort theme without indexorder while comparing $a and $b" 
                                if(!defined($self -> {"mdata"} -> {"themes"} -> {$a} -> {"theme"} -> {"indexorder"}) or !defined($self -> {"mdata"} -> {"themes"} -> {$b} -> {"theme"} -> {"indexorder"}));

                            return $self -> {"mdata"} -> {"themes"} -> {$a} -> {"theme"} -> {"indexorder"} <=> $self -> {"mdata"} -> {"themes"} -> {$b} -> {"theme"} -> {"indexorder"};
                          }
                          keys(%{$self -> {"mdata"} -> {"themes"}});
    
    # Now we can process all the modules in the theme...
    my $body = "";
    foreach my $theme (@themenames) {
        # skip themes that won't be included in the course
        next if($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"exclude_resource"});

        # generate the index for the module, and shove it into a theme entry
        $body .= $self -> {"template"} -> load_template("index_theme.tem",
                                                        {"***name***"    => $theme,
                                                         "***title***"   => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"title"},
                                                         "***modules***" => $self -> build_index_modules($theme, "course")});
    } # foreach $theme (@themenames)

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Scanning index for media file use.");
    $self -> scan_step_media($body);

    # dump the index.
    save_file(path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, "courseindex.html"),
              $self -> {"template"} -> load_template("courseindex.tem",
                                                     {"***body***"         => $body,
                                                      "***title***"        => $self -> {"mdata"} -> {"course"} -> {"title"}." course index",

                                                      # Standard stuff
                                                      "***glosrefblock***"  => $self -> build_glossary_references("course"),
                                                      "***include***"       => $self -> get_extrahead("course"),
                                                      "***version***"       => $self -> {"mdata"} -> {"course"} -> {"version"},
                                                     }));
}


## @method void write_course_index()
# Generate the course map page. This will either automatically generate a series of 
# buttons arranged in a table from which users may choose a thing to view, or if the
# course metadata contains a user-defined map it will use that instead.
sub write_course_index {
    my $self = shift;
    my $body;

    # Does the course explicity provide a course map?
    if($self -> {"mdata"} -> {"course"} -> {"maps"} &&
       $self -> {"mdata"} -> {"course"} -> {"map"} &&
       scalar($self -> {"mdata"} -> {"course"} -> {"map"})) {

        foreach my $map (@{$self -> {"mdata"} -> {"course"} -> {"maps"} -> {"map"}}) {
            # Skip maps that should not be included
            if(!$self -> {"filter"} -> includes_filter($map)) {
                $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Map ".substr((ref($map) eq "HASH" ? $map -> {"content"} : $map), 0, 16)."... excluded by filter rule");
                next;
            }

            # The map is being included, so add its contents to the map body
            $body .= (ref($map) eq "HASH" ? $map -> {"content"} : $map);
        }

        # Better scan the text for media to retain
        $self -> scan_step_media($body);
    } 


    # If we get here with no body set, either the user has not specified any
    # or all the specified maps failed filtering checks
    if(!$body) {
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "No course map specified, or all maps filtered out. Generating map.");

        # We need a sorted list of themes...
        my @themenames = sort { die "Attempt to sort theme without indexorder while comparing $a and $b" 
                                    if(!defined($self -> {"mdata"} -> {"themes"} -> {$a} -> {"theme"} -> {"indexorder"}) or !defined($self -> {"mdata"} -> {"themes"} -> {$b} -> {"theme"} -> {"indexorder"}));

                                return $self -> {"mdata"} -> {"themes"} -> {$a} -> {"theme"} -> {"indexorder"} <=> $self -> {"mdata"} -> {"themes"} -> {$b} -> {"theme"} -> {"indexorder"};
                              }
                              keys(%{$self -> {"mdata"} -> {"themes"}});
    
        # Build the paths we will need...
        my $relpath = path_join($self -> {"config"} -> {"Processor"} -> {"mediadir"}, "generated");
        my $imgpath = path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, $relpath);

        # And make sure the path exists
        if(!-e $imgpath) {
            make_path($imgpath)
                or die "FATAL: Unable to create generated media directory: $!\n";
        }

        # Now, for each theme we need to generate on and off buttons, and a html fragment
        my @outlist;
        foreach my $theme (@themenames) {  
            # skip themes we don't need to process
            next if($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"exclude_resource"});

            # Buttons first...
            my $errors = $self -> {"imagetools"} -> load_render_xml("theme_button_off.xml", 
                                                                    {"***theme_title***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"title"} },
                                                                    path_join($imgpath, "cmap_".$theme."_off.png"));
            die "FATAL: Unable to generate $theme off image: $errors\n" if($errors);

            $errors = $self -> {"imagetools"} -> load_render_xml("theme_button_on.xml", 
                                                                 {"***theme_title***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"title"} },
                                                                 path_join($imgpath, "cmap_".$theme."_on.png"));
            die "FATAL: Unable to generate $theme off image: $errors\n" if($errors);

            # the span has to be handled later, as at this point we can't assume that
            # scalar(@themenames) is the number of themes that will end up generated.
            push(@outlist, $self -> {"template"} -> load_template("map_cell.tem",
                                                                  {"***name***"     => $theme,
                                                                   "***mediadir***" => $relpath,
                                                                   "***button***"   => "cmap_".$theme,
                                                                   "***title***"    => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"title"}}));
        }

        # Need to store the table somewhere.
        my $tablebody;

        # Now we have cell fragments and a count of themes, we can work out how
        # to lay the content out. We favour a single cell on the first row when there are
        # an odd number of rows.
        my $cellcount = scalar(@outlist);
        my $cell = 0; 
        while($cell < $cellcount) {
            # If this is the first cell, and the cell count is odd, we want a single cell on the row
            if(($cell == 0) && ($cellcount % 2 == 1)) {
                $tablebody .= $self -> {"template"} -> load_template("map_row.tem", 
                                                                     {"***cells***" => $self -> {"template"} -> process_template($outlist[$cell++], 
                                                                                                                                 {"***span***" => 'colspan="2"'})});
            # Otherwise, we want to pull out two cells at a time
            } else {
                $tablebody .= $self -> {"template"} -> load_template("map_row.tem", 
                                                                     {"***cells***" => $self -> {"template"} -> process_template($outlist[$cell++], {"***span***" => ''}).
                                                                                       $self -> {"template"} -> process_template($outlist[$cell++], {"***span***" => ''})});
            }
        }

        # And the body is just the table body wrapped in, well, a table..
        $body = $self -> {"template"} -> load_template("map.tem", {"***rows***" => $tablebody});
    }

    # dump the index.
    save_file(path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, "coursemap.html"),
              $self -> {"template"} -> load_template("coursemap.tem",
                                                     {"***body***"         => $body,
                                                      "***title***"        => $self -> {"mdata"} -> {"course"} -> {"title"}." course index",

                                                      # Standard stuff
                                                      "***glosrefblock***"  => $self -> build_glossary_references("course"),
                                                      "***include***"       => $self -> get_extrahead("course"),
                                                      "***version***"       => $self -> {"mdata"} -> {"course"} -> {"version"},
                                                     }));
}


## @method void write_course_frontpage()
# Write out the course front page file. This will generate a page containing any
# message set in the course metadata, and a graphic (animation or image) beside it.
# Note that the media used on front page does not need to be listed in the course
# forced media list.
sub write_course_frontpage {
    my $self = shift;

    # create the graphic element(s)
    my $graphic = $self -> {"template"} -> load_template("frontpage-".$self -> {"mdata"} -> {"course"} -> {"type"}.".tem", 
                                                         {"***mediadir***" => $self -> {"config"} -> {"Processor"} -> {"mediadir"},
                                                          "***filename***" => $self -> {"mdata"} -> {"course"} -> {"splash"},
                                                          "***width***"    => $self -> {"mdata"} -> {"course"} -> {"width"},
                                                          "***height***"   => $self -> {"mdata"} -> {"course"} -> {"height"},
                                                          "***title***"    => $self -> {"mdata"} -> {"course"} -> {"title"}});

    # store the filename so it doesn't get cleaned up
    $self -> {"used_media"} -> {lc($self -> {"mdata"} -> {"course"} -> {"splash"})} = $self -> {"mdata"} -> {"course"} -> {"splash"};

    # dump the page.
    save_file(path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, "frontpage.html"),
              $self -> {"template"} -> load_template("frontpage.tem",
                                                     {"***bodytext***"      => $self -> {"mdata"} -> {"course"} -> {"message"} || "No course message provided",
                                                      "***graphic***"       => $graphic,
                                                      "***title***"         => $self -> {"mdata"} -> {"course"} -> {"title"},
                                                      
                                                      # Standard stuff
                                                      "***glosrefblock***"  => $self -> build_glossary_references("course"),
                                                      "***include***"       => $self -> get_extrahead("course"),
                                                      "***version***"       => $self -> {"mdata"} -> {"course"} -> {"version"},
                                                     }));
}


# ============================================================================
#  Dropdown handling
#  

## @method $ is_related($theme, $module, $mode, $check)
# Determine whether the module name specified exists as a prerequisite or leadsto
# for the specified module. This will check the specified module's prerequisite
# or leadsto lists (depending on the mode specified) and return true if the named
# check module exists in that list, and false otherwise.
#
# @param theme  The theme the module resides within.
# @param module The name of the current module.
# @param mode   The list to check - should be "prerequisites" or "leadsto".
# @param check  The name of the module to check.
# @return true if check is in the appropriate list for the current module, false 
#         if it is not.
sub is_related {
    my $self    = shift;
    my $theme   = shift;
    my $module  = shift;
    my $mode    = shift;
    my $check   = shift;

    # do nothing if there are no entries
    return 0 if (!$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {$mode} ||
                 !$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {$mode} -> {"target"} ||
                 !scalar($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {$mode} -> {"target"}));

    # return true if the name we are supposed to check appears in the list
    foreach my $entry (@{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {$mode} -> {"target"}}) {
        return 1 if($entry eq $check);
    }
                 
    return 0;
}


## @method $ build_theme_dropdowns()
# Generate the theme dropdowns shown on theme map and theme index pages, and included
# in each step nav menu. This generates two partially-processed dropdown menus, and
# get_theme_dropdown() should be called to complete the processing before inserting 
# into the target template. $self -> {"dropdowns"} -> {"theme_themeview"} stores the
# theme level dropdown, while $self -> {"dropdowns"} -> {"theme_stepview"} stores 
# the equivalent step dropdown.
# 
# @note This will die if any theme is missing its indexorder, although the metadata
#       validation should have failed if it does not!
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
                          keys(%{$self -> {"mdata"} -> {"themes"}});

    # Build the ordered list of themes for both levels.
    foreach my $theme (@themenames) {
        # skip themes that won't be included in the course
        next if($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"exclude_resource"});

        $themedrop_theme  .= $self -> {"template"} -> load_template("theme/themedrop-entry.tem",
                                                                    { "***name***"  => $theme,
                                                                      "***title***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"title"}});

        $themedrop_module .= $self -> {"template"} -> load_template("theme/module/themedrop-entry.tem",
                                                                    { "***name***"  => $theme,
                                                                      "***title***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"title"}});
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
#
# @param theme  The name of the theme to generate the step dropdown for.
# @param module The name of the module to generate the step dropdown for.
sub build_step_dropdowns {
    my $self   = shift;
    my $theme  = shift;
    my $module = shift;

    my $stepdrop = "";

    # Process the list of steps for this module, sorted by numeric order. Steps are stored using a numeric
    # step id (not 'nodeXX.html' as they were in < 3.7)
    foreach my $step (sort numeric_order keys(%{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"}})) {
        # Skip steps with no output id
        next if(!$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$step} -> {"output_id"});

        $stepdrop .= $self -> {"template"} -> load_template("theme/module/stepdrop-entry.tem",
                                                            { "***name***"  => get_step_name($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$step} -> {"output_id"}),
                                                              "***title***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$step} -> {"title"}});
    }
     
    die "FATAL: No steps stored for \{$theme\} -> \{$module\} -> \{steps\}\n" if(!$stepdrop);

    # and store the partially-processed dropdown
    $self -> {"dropdowns"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} = $self -> {"template"} -> load_template("theme/module/stepdrop.tem",
                                                                                                                                    {"***entries***" => $stepdrop });
}


## @method void build_module_dropdowns($theme)
# Generate the completed module dropdowns for each module in the specified theme, and
# the partially processed dropdowns for the steps in each module. 
#
# @note This will die if any module is missing its indexorder, although this should
#       not happen if the metadata was validated during loading.
#
# @param theme The name of the theme to generate the module dropdown for.
sub build_module_dropdowns {
    my $self  = shift;
    my $theme = shift;

    my @modulenames =  sort { die "Attempt to sort module without indexorder while comparing $a and $b" 
                                  if(!$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"} or !$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$b} -> {"indexorder"});
                                  
                              return $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"} <=> $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$b} -> {"indexorder"};
                            }
                            keys(%{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"}});

    foreach my $module (@modulenames) {
        my $moduledrop = "";
            
        # skip modules that won't be included in the course
        next if($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"exclude_resource"});

        # first create the module dropdown for this module (ie: show all modules in this theme and how they relate)
        foreach my $buildmod (@modulenames) {
            my $relationship = "";
                
            # skip modules that won't be included in the course
            next if($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$buildmod} -> {"exclude_resource"});

            # first determine whether buildmod is a prerequisite, leadsto or the current module
            if($buildmod eq $module) {
                $relationship = "-current";
            } elsif($self -> is_related($theme, $module, "prerequisites", $buildmod)) {
                $relationship = "-prereq";
            } elsif($self -> is_related($theme, $module, "leadsto", $buildmod)) {
                $relationship = "-leadsto";
            } 

            $moduledrop .= $self -> {"template"} -> load_template("theme/module/moduledrop-entry".$relationship.".tem",
                                                                  { "***level***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$buildmod} -> {"level"},
                                                                    "***title***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$buildmod} -> {"title"},
                                                                    "***name***"  => $buildmod });
        }

        # store the generated menu for this module
        $self -> {"dropdowns"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"modules"} = $self -> {"template"} -> load_template("theme/module/moduledrop.tem",
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
    foreach my $theme (@$themenames) {
        $self -> build_module_dropdowns($theme);
    }
}


## @method $ get_theme_dropdown($theme, $mode)
# Generate a string containing the theme dropdown menu with the current theme 
# marked. The menu produced is suitable for use in steps if the mode argument is
# set to "step", and for theme maps/indexes if it is set to "theme".
#
# @param theme The current theme.
# @param mode  Should be "step" to generate a step-level theme dropdown, or "theme"
#              to generate a theme-level dropdown. Any other value will cause the
#              function to die.
# @return A string containing the theme dropdown.
sub get_theme_dropdown {
    my $self  = shift;
    my $theme = shift;
    my $mode  = shift;
    my $level;

    if($mode eq "step") {
        $level = "theme/module";
    } elsif($mode eq "theme") {
        $level = "theme";
    } else {
        die "FATAL: Illegal mode passed to get_theme_dropdown(). This should not happen!\n";
    }

    # Load the chunk that needs to be located in the dropdown
    my $anchor = $self -> {"template"} -> load_template("$level/themedrop-entry.tem",
                                                        { "***name***"  => $theme,
                                                          "***title***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"title"}});
                                       
    # And the chunk that should replace the bit above
    my $replace = $self -> {"template"} -> load_template("$level/themedrop-entry-current.tem",
                                                         { "***name***"  => $theme,
                                                           "***title***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"title"}});

 
    die "FATAL: Unable to open anchor template themedrop-entry.tem: $!"  if(!$anchor);
    die "FATAL: Unable to open replace template themedrop-entry.tem: $!" if(!$replace);

    # copy the theme dropdown so we can wrangle it
    my $dropdown = $self -> {"dropdowns"} -> {"themes_".$mode."view"};

    # replace the current theme
    $dropdown =~ s/\Q$anchor\E/$replace/;

    # now nuke the remainder of the current tags
    $dropdown =~ s/\*\*\*current\*\*\*//g;

    return $dropdown;
}


## @method $ get_step_dropdown($theme, $module, $stepid)
# Obtain a string for the step dropdown, marking the current step so it can be 
# inserted into the step body.
#
# @param theme  The theme the step is in.
# @param module The module the step is in.
# @param stepid The ID of the current step.
# @return A string containing the step dropdown for the step.
sub get_step_dropdown {
    my $self   = shift;
    my $theme  = shift;
    my $module = shift;
    my $stepid = shift;

    # set up a chunk to use as an anchor in the menu
    my $anchor = $self -> {"template"} -> load_template("theme/module/stepdrop-entry.tem",
                                                        { "***name***"  => get_step_name($stepid),
                                                          "***title***" => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$stepid} -> {"title"} });

    # this chunk will replace the above
    my $replace = $self -> {"template"} -> load_template("theme/module/stepdrop-entry-current.tem",
                                                         { "***name***"    => get_step_name($stepid),
                                                           "***title***"   => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$stepid} -> {"title"} });
    
    die "FATAL: Unable to open anchor template stepdrop-entry.tem: $!"  if(!$anchor);
    die "FATAL: Unable to open replace template stepdrop-entry.tem: $!" if(!$replace);

    # Create a copy of the step dropdown so it can be modified
    my $dropdown = $self -> {"dropdowns"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"};

    # replace the current step
    $dropdown =~ s/\Q$anchor\E/$replace/;
    
    # and nuke the remainder of the current markers
    $dropdown =~ s/\*\*\*current\*\*\*//g;

    return $dropdown;
}


# ============================================================================
#  Cleanup code.
#  

## @method void cleanup_module($moddir)
# Remove all intermediate files from the specified module directory. When the
# global debugging mode is disabled, this will remove all node*.html files 
# from the specified module directory. If debugging is enabled, this does nothing.
#
# @param moddir The mdoule to remove the intermediate files from.
sub cleanup_module {
    my $self   = shift;
    my $moddir = shift;

    # do nothing if we have debug mode enabled
    return if($self -> {"config"} -> {"Processor"} -> {"debug"});

    my $out = `$self->{config}->{paths}->{rm} -fv $moddir/node*.html`;
    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Cleanup output:\n$out");
}


# ============================================================================
#  Postprocess
#

## @method void framework_merge()
# Merge the framework directory into the output, rewriting the content into the
# templates as needed.
sub framework_merge {
    my $self = shift;

    # The framework is inside the template directory
    my $framedir = path_join($self -> {"template"} -> {"templatedir"}, "framework");

    # Open the framework directory so that we can go through the list of files therein
    opendir(FRAME, $framedir)
        or die "FATAL: Unable to open framework directory: $!\n";

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Merging framework to output...");

    my $outdir = $self -> {"config"} -> {"Processor"} -> {"outputdir"};
    while(my $entry = readdir(FRAME)) {
        next if($entry =~ /^\./);

        # Cache the filename, to make life easier later
        my $entryfile = path_join($framedir, $entry);

        # if the entry is a directory then we want to simply copy it (NOTE: This behaviour depends
        # on the framework html files being in the top level of the tree. Were this is not the case
        # then far more advanced path handling would be required in generating the templated pages.
        # Unless there is a /blindingly/ good reason, I suggest avoiding changing this setup!)
        if(-d $entryfile) {
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Copying directory $entry and its contents to $outdir...");
            my $out = `$self->{config}->{paths}->{cp} -rv $entryfile $outdir`;
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "cp output is:\n$out");
        
        # convert templates
        } elsif($entry =~ /\.tem?$/) {
            my ($name) = $entry =~ /^(.*?)\.tem?$/;
            die "FATAL: Unable to get name from $entry!" if(!$name);
            
            save_file(path_join($outdir, "$name.html"),
                      $self -> {"template"} -> load_template(path_join("framework", $entry),
                                                             {"***glosrefblock***"  => $self -> build_glossary_references("course"),
                                                              "***version***"       => $self -> {"mdata"} -> {"course"} -> {"version"}}));

        # otherwise just straight-copy the file, as we don't know what to do with it
        } else {
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Copying $entry to $outdir...");
            my $out = `$self->{config}->{paths}->{cp} -rv $framedir/$entry $outdir`;
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "cp output is: $out");
        }   
    }

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Merge complete.");

    closedir(FRAME);
}


# ============================================================================
#  Preprocessing code.
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
#       glossary definitions and reference definitions (but not references to them) 
#       even if a theme, module, or step they occur in is filtered out of the final 
#       course. This is necessary because the definition of a term may only be present 
#       in a resource that will be filtered out, but references to it may exist 
#       elsewhere in the course. It should be noted that link anchors *will not* be 
#       stored if the resource will be excluded.
sub preprocess {
    my $self = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Starting preprocesss.");

    # A bunch of references to hashes built up as preprocessing proceeds.
    $self -> {"terms"} = { } if(!defined($self -> {"terms"}));
    $self -> {"refs"}  = { } if(!defined($self -> {"refs"}));

    # And a counter to keep track of how many files need processing
    $self -> {"stepcount"} = 0;

    # Load the course metadata here. We don't need it, but it'll be useful later.
    $self -> {"mdata"} = $self -> {"metadata"} -> load_metadata($self -> {"config"} -> {"Processor"} -> {"outputdir"}, "course", 1);
    die "FATAL: Unable to load course metadata.\n"
        if(!defined($self -> {"mdata"} -> {"course"}) || ref($self -> {"mdata"} -> {"course"}) ne "HASH");

    # We no longer need the course metadata
    unlink path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, "metadata.xml") 
        unless($self -> {"config"} -> {"Processor"} -> {"debug"});

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
            my $metadata = $self -> {"metadata"} -> load_metadata($fulltheme, "theme '$theme'", 1);

            # skip directories without metadata, or non-theme metadata
            next if($metadata == 1 || !$metadata -> {"theme"});

            $self -> {"mdata"} -> {"themes"} -> {$theme} = $metadata; # otherwise, store it.

            # We can remove the theme metadata now
            unlink path_join($fulltheme, "metadata.xml") 
                unless($self -> {"config"} -> {"Processor"} -> {"debug"});

            # Determine whether this theme will actually end up in the generated course
            my $exclude_theme = $self -> {"filter"} -> exclude_resource($metadata -> {"theme"});

            # Store the exclude for later use
            $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"exclude_resource"} = $exclude_theme;

            # Now we need to get a list of modules inside the theme. This looks at the list of modules 
            # stored in the metadata so that we don't need to worry about non-module directoried...
            foreach my $module (keys(%{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"}})) {
                my $fullmodule = path_join($fulltheme, $module); # prepend the module directory...

                # Determine whether the module will be included in the course (it will always be
                # excluded if the theme is excluded)
                my $exclude_module = $exclude_theme || $self -> {"filter"} -> exclude_resource($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module});

                # Store the exclude for later use
                $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"exclude_resource"} = $exclude_module;

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

                        my @sortedsteps = sort step_sort @steps;

                        my $outstep = 0;
                        foreach my $step (@sortedsteps) {
                            my ($stepid) = $step =~ /^node0?(\d+).html/;

                            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Preprocessing $fullmodule/$step... ");

                            my $content = load_file($step)
                                or die "FATAL: Unable to open step file '$fullmodule/$step': $!\n";

                            my ($title) = $content =~ m{<title>\s*(.*?)\s*</title>}im;

                            # If we have a step entry in the metadata, check whether this step will be excluded
                            # (it will be excluded if the module is, or the step is listed in the metadata and
                            # is excluded)
                            my $exclude_step = $exclude_module ||
                                ($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} &&
                                 $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$title} &&
                                 $self -> {"filter"} -> exclude_resource($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$title}));

                            # Record the locations of any anchors in the course
                            if(!$exclude_step) {
                                pos($content) = 0;
                                while($content =~ /\[target\s+name\s*=\s*\"([-\w]+)\"\s*\/?\s*\]/isg) {
                                    $self -> set_anchor_point($1, $theme, $module, $stepid);
                                }
                            }

                            # reset so we can scan for glossary terms
                            pos($content) = 0; 
                            # first look for definitions...
                            while($content =~ m{\[glossary\s+term\s*=\s*\"([^\"]+?)\"\s*\](.*?)\[\/glossary\]}isg) {
                                $self -> set_glossary_point($1, $2, $theme, $module, $step, $title, !$exclude_step);
                            }

                            # Now look for references to the terms...
                            pos($content) = 0; 
                            while($content =~ m{\[glossary\s+term\s*=\s*\"([^\"]+?)\"\s*\/\s*\]}isg) {
                                $self -> set_glossary_point($1, undef, $theme, $module, $step, $title, !$exclude_step);
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
                                $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Recording $title step $stepid as $theme -> $module -> steps -> $step");
                                $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$stepid} -> {"title"}     = $title;
                                $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$stepid} -> {"filename"}  = $step;
                                $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$stepid} -> {"output_id"} = lead_zero(++$outstep);

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

        } # if(-d $fulltheme)
    } # foreach my $theme (@themes)

    closedir(SRCDIR);

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Complete metadata tree is:\n".Data::Dumper -> Dump([$self -> {"mdata"}]));
    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Building navigation menus.");
    $self -> build_dropdowns();

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Finished preprocesss.");
}


# ============================================================================
#  Media usage check and cleanup
#  

## @method void scan_step_media($body)
# Scan the contents of the specified step, adding any media files detected to the
# 'used_media' hash stored in the plugin object. This allows the plugin to determine
# which files can be safely removed from the media directory after cleanup.
#
# @param body The body of the step to scan.
sub scan_step_media {
    my $self = shift;
    my $body = shift;

    # we could use this straight in the regexp, but this is more readable
    my $mediadir = $self -> {"config"} -> {"Processor"} -> {"mediadir"};

    # Grab a list of media files in the step. This will try to pull out anything
    # between the mediadir name and a speechmark
    my @files = $body =~ m|$mediadir/(.*?)["'\b]|g;

    # Mark all these files in the used_media hash
    foreach my $file (@files) {
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Adding used media file $file.");
        # Check whether the image is already marked as used, and that the case is correct
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Media file case error: $file has already been added as ".$self -> {"used_media"} -> {lc($file)})
            if($self -> {"used_media"} -> {lc($file)} && $self -> {"used_media"} -> {lc($file)} ne $file);

        $self -> {"used_media"} -> {lc($file)} = $file;
    }
}


## @method void cleanup_media()
# Remove any files from the media directory that do not appear in the used_media
# hash or forcemedia list.
sub cleanup_media {
    my $self = shift;

    # Process any entries in the forcemedia list into the used_media hash
    # for lookup convenience
    if($self -> {"mdata"} -> {"course"} -> {"forcemedia"} && $self -> {"mdata"} -> {"course"} -> {"forcemedia"} -> {"file"}) {
        foreach my $file (@{$self -> {"mdata"} -> {"course"} -> {"forcemedia"} -> {"file"}}) {
            $self -> {"used_media"} -> {lc($file)} = $file;
        }
    }

    my $mediadir = path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, $self -> {"config"} -> {"Processor"} -> {"mediadir"});

    # Get a list of filenames in the media directory
    opendir(MEDIA, $mediadir)
        or die "FATAL: Unable to open media directory ($mediadir) for reading: $!\n";
    my @names = readdir(MEDIA);
    closedir(MEDIA);

    # Now go through the files
    foreach my $filename (@names) {
        # skip directories - this will let through some resources, but not enough to worry about
        # FIXME: investigate ways to deal with subdirs of media
        next if(-d path_join($mediadir, $filename));

        # Otherwise, if the file is not in the used media, remove it
        if(!$self -> {"used_media"} -> {lc($filename)}) {
            
            $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Removing unused media file $filename.");

            unlink path_join($mediadir, $filename)
                or die "FATAL: Unable to delete unused media file $filename: $!\n";

        # Would the file be usable if its case were different?
        } elsif($self -> {"used_media"} -> {lc($filename)} && $self -> {"used_media"} -> {lc($filename)} ne $filename) {
            $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Media file $filename has the wrong case. Renaming to ".$self -> {"used_media"} -> {lc($filename)});

            rename path_join($mediadir, $filename), path_join($mediadir, $self -> {"used_media"} -> {lc($filename)})
                or die "FATAL: Unable to rename $filename: $!\n";
        } else {
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Media file $filename is in use, retaining.");
        }
    }
}


# ============================================================================
#  Step processing and tag conversion code.
#  

## @fn $ media_alignment_class($align)
# Convert a human-readable alignment ('left', 'right', 'center') into a class
# name to apply to a media container div.
#
# @param align The alignment to convert.
# @return The class to use for the media container div.
sub media_alignment_class {
    my $align = shift;

    if($align) {
        if($align =~ /^left$/i) {
            return "floatleft";
        } elsif($align =~ /^right$/i) {        
            return "floatright";
        } elsif($align =~/^center$/i) {
            return "center";
        }
    }

    return "floatleft";
}


## @method $ convert_image($tagdata)
# Convert an image tag to html markup. This processes the specified list of tag args
# and generates an appropriate html image element, or an error message to include
# in the document.
#
# @param tagdata  The image tag attribute list
# @return The string to replace the image tag with - either a html image element,
#         or an error message.
sub convert_image {
    my $self    = shift;
    my $tagdata = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Use of deprecated [image] tag with attributes '$tagdata'"); 

    # Convert the tag arguments into an attribute hash
    my %attrs = $tagdata =~ /(\w+)\s*=\s*\"([^\"]+)\"/g;

    # Generate an error if we have no image name
    if(!$attrs{"name"}) {
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Image tag attribute list does not include name.");
        return "<p class=\"error\">Image tag attribute list does not include name.</p>";
    }

    # Work out the alignment class for the image
    my $divclass = media_alignment_class($attrs{"align"});

    # The image style deals with width, height, and other stuff...
    my $imgstyle = "border: none;";
    $imgstyle .= " width: $attrs{width};"   if($attrs{"width"});
    $imgstyle .= " height: $attrs{height};" if($attrs{"height"});

    return $self -> {"template"} -> load_template("theme/module/image.tem",
                                                  {"***name***"     => $attrs{"name"},
                                                   "***mediadir***" => $self -> {"config"} -> {"Processor"} -> {"mediadir"},
                                                   "***divclass***" => $divclass,
                                                   "***imgstyle***" => $imgstyle,
                                                   "***alt***"      => $attrs{"alt"} || "image",
                                                   "***title***"    => $attrs{"title"} || "image"});
}


## @method $ convert_anim($tagdata)
# Convert an anim tag to html markup. This processes the specified list of tag args
# and generates the html elements needed to include a flash movie, or an error 
# message to include in the document.
#
# @param tagdata  The anim tag attribute list
# @return The string to replace the animtag with - either a chunk of html,
#         or an error message.
sub convert_anim {
    my $self    = shift;
    my $tagdata = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Use of deprecated [anim] tag with attributes '$tagdata'"); 

    # Convert the tag arguments into an attribute hash
    my %attrs = $tagdata =~ /(\w+)\s*=\s*\"([^\"]+)\"/g;

    # A name is needed for the animation
    if(!$attrs{"name"}) {
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Anim tag attribute list does not include name.");
        return "<p class=\"error\">Anim tag attribute list does not include name.</p>";
    }

    # Width and height are needed as well
    if(!$attrs{"width"} || !$attrs{"height"}) {
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Anim tag attribute list is missing width or height information.");
        return "<p class=\"error\">Anim tag attribute list is missing width or height information.</p>";
    }
     
    # obtain the alignment class for the container
    my $divclass = media_alignment_class($attrs{"align"});

    return $self -> {"template"} -> load_template("theme/module/anim.tem",
                                                  {"***name***"     => $attrs{"name"},
                                                   "***mediadir***" => $self -> {"config"} -> {"Processor"} -> {"mediadir"},
                                                   "***divclass***" => $divclass,
                                                   "***width***"    => $attrs{"width"},
                                                   "***height***"   => $attrs{"height"}});
}


## @method $ convert_applet($tagdata)
# Applet support has been removed; this prints a warning and returns an error.
#
# @param tagdata  The applet tag attribute list
# @return An error message.
sub convert_applet {
    my $self    = shift;
    my $tagdata = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Applet support has been removed. If you require applet support, contact Chris.");
    
    return "<p class=\"error\">Applets are no longer supported by the APEcs processor.</p>";    
}


## @method $ convert_local($args, $data)
# Converts a local tag into the appropriate html. This will process the specified
# arguments and data into a popup on the page.
#
# @param args The arguments to the local tag.
# @param data The contents of the popup. Should be valid html.
# @return The string to replace the local tag with, or an error message.
sub convert_local {
    my $self  = shift;
    my $args  = shift;
    my $body  = shift;

    # Pull out the title from the arguments
    my ($title) = $args =~ /text="([^"]+)"/si;

    # Other arguments are discarded in this version as they no longer have any real meaning.

    return $self -> {"template"} -> load_template("theme/module/popup.tem",
                                                  {"***title***" => $title,
                                                   "***body***"  => encode_base64($body),
                                                  });
}


## @method $ convert_step_tags($content, $theme, $module, stepid)
# Convert any processor markup tags in the supplied step text into the equivalent 
# html. This function scans the provided text for any of the special marker tags
# supported by the processor and replaces them with the appropriate html, using
# the various convert_ functions as needed to support the process.
#
# @param content The step text to process.
# @param theme   The theme the step resides within.
# @param module  The module the step is in.
# @param stepid  The step's id number.
# @return The processed step text.
sub convert_step_tags {
    my $self    = shift;
    my $content = shift;
    my $theme   = shift;
    my $module  = shift;
    my $stepid  = shift;

    # Glossary conversion
    $content =~ s{\[glossary\s+term\s*=\s*"(.*?)"\s*\/\s*\]}{$self->convert_glossary_term($1)}ige;              # [glossary term="" /]
    $content =~ s{\[glossary\s+term\s*=\s*"(.*?)"\s*\].*?\[/glossary\]}{$self->convert_glossary_term($1)}igse;  # [glossary term=""]...[/glossary]

    # Image conversion
    $content =~ s{\[img\s+(.*?)\/?\s*\]}{$self -> convert_image($1)}ige;  # [img name="" width="" height="" alt="" title="" align="left|right|center" /]

    # Anim conversion
    $content =~ s/\[anim\s+(.*?)\/?\s*\]/$self -> convert_anim($1)/ige;   # [anim name="" width="" height="" align="left|right|center" /]

    # Applet conversion
    # Remove entirely in 3.8?
    $content =~ s/\[applet\s+(.*?)\/?\s*\]/$self -> convert_applet($1)/ige; # [anim name="" width="" height="" codebase="" archive="" /]

    # clears
    $content =~ s/\[clear\s*\/?\s*\]/<div style="clear: both;"><\/div>/giso; # [clear /]

    # links
    $content =~ s{\[link\s+(?:to|name)\s*=\s*\"(.*?)\"\s*\](.*?)\[/\s*link\s*\]}{$self -> convert_link($1, $2, 'step')}isge; # [link to=""]link text[/link]

    # anchors
    $content =~ s/\[target\s+name\s*=\s*\"(.*?)\"\s*\/?\s*\]/<a name=\"$1\"><\/a>/gis; # [target name="" /]

    # Local conversion
    $content =~ s/\[local\s+(.*?)\s*\](.*?)\[\/\s*local\s*\]/$self -> convert_local($1, $2)/isge;

    # convert references and do any work needed to compress them (eg: converting [1][2][3] to [1,2,3])
    if($self -> {"refhandler"}) {
        $content =~ s/\[ref\s+(.*?)\s*\/?\s*\]/$self -> {"refhandler"} -> convert_references($1)/ige;
        $content = $self -> {"refhandler"} -> compress_references($content);
    }

    return $content;
}


## @method void process_step($theme, $module, $stepid, $laststep)
# Convert thestep identified by the specified theme, module, and step id from the 
# intermediate format data files into a processed, templated course step. This will
# load the intermediate format data for the specified step from the filesystem, 
# apply any necessary tag conversions to the body, and write out a templated step
# file.
#
# @param theme    The theme the step resides within.
# @param module   The module the step is in.
# @param stepid   The ID of the step to process, must be 1 <= stepid <= laststep
# @param laststep The ID of the last step that will be generated in the module.
sub process_step {
    my $self      = shift;
    my $theme     = shift;
    my $module    = shift;
    my $stepid    = shift;
    my $laststep  = shift;

    # Load the step content
    my $content = load_file($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$stepid} -> {"filename"})
        or die "FATAL: Unable to open step file '".$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$stepid} -> {"filename"}."': $!\n";
    
    # extract the bits we're interested in...
    # IMPORTANT: This code has been modified from 3.6 behaviour to not strip trailing <hr>s out of
    # content. This should not break wiki export, but will break files generated by the latex input
    # plugin unless that strips the junk before writing to the intermediate file format.
    my ($title, $body) = $content =~ m|<title>\s*(.*?)\s*</title>.*<body.*?>\s*(.*?)\s*</body>|si;

    # We need title and body parts
    die "FATAL: Unable to read body from step file '".$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"} -> {$stepid} -> {"filename"}."'\n" 
        if(!$title || !$body);

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Obtained body for step $stepid, title is $title. Processing body.");

    # tag conversion
    $body = $self -> convert_step_tags($body, $theme, $module, $stepid);

    # Build the navigation data we need for the step
    my $navhash = $self -> build_navlinks($stepid, $laststep, $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"level"});
    
    # Save the step out as a templated step...
    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing out processed data to ".get_step_name($stepid));
    save_file(get_step_name($stepid), 
              $self -> {"template"} -> load_template("theme/module/step.tem",
                                                     {# Basic content
                                                      "***title***"         => $title,
                                                      "***body***"          => $body,

                                                      # Navigation buttons
                                                      "***previous***"      => $navhash -> {"button"} -> {"previous"},
                                                      "***next***"          => $navhash -> {"button"} -> {"next"},

                                                      # Header <link> elements
                                                      "***startlink***"     => $navhash -> {"link"} -> {"first"},
                                                      "***prevlink***"      => $navhash -> {"link"} -> {"previous"},
                                                      "***nextlink***"      => $navhash -> {"link"} -> {"next"},
                                                      "***lastlink***"      => $navhash -> {"link"} -> {"last"},

                                                      # Module complexity (difficulty is uc(level) for readability)
                                                      "***level***"         => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"level"},
                                                      "***difficulty***"    => ucfirst($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"level"}),

                                                      # theme/module for title and breadcrumb
                                                      "***themename***"     => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"title"},
                                                      "***modulename***"    => $self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"title"},

                                                      # Dropdowns in the menu bar
                                                      "***themedrop***"     => $self -> get_theme_dropdown($theme, "step"),
                                                      "***moduledrop***"    => $self -> {"dropdowns"} -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"modules"},
                                                      "***stepdrop***"      => $self -> get_step_dropdown($theme, $module, $stepid),

                                                      # Standard stuff
                                                      "***glosrefblock***"  => $self -> build_glossary_references("module"),
                                                      "***include***"       => $self -> get_extrahead("step"),
                                                      "***version***"       => $self -> {"mdata"} -> {"course"} -> {"version"},
                                                     }));

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing complete.");

    # Try to do tidying if the tidy mode has been specified and it exists
    if($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidy"}) {
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Tidying ".get_step_name($stepid));

        die "FATAL: Unable to run htmltidy: tidy does not exist at ".$self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidycmd"}."\n"
            if(!-e $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidycmd"});

        my $name = get_step_name($stepid);

        # make a backup if we're running in debug mode
        `$self->{config}->{paths}->{cp} -f $name $name.orig` if($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidybackup"});

        # Now invoke tidy
        my $cmd = $self -> {"config"}-> {"HTMLOutputHandler"} -> {"tidycmd"}." ".
            $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidyargs"}." -m $name";
        
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Invoing tidy using: $cmd");
        my $out = `$cmd 2>&1`;

        # Echo the output if needed so that debugging of tidy is doable.
        $self -> {"tidyout"} .= "=== Tidy warnings for $theme/$module/$title:\n$out" if($out && $out !~ /^\s*$/);
    }

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Scanning step for media file use.");
    $self -> scan_step_media($body);

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Step processing complete");
}

1;
