## @file
# This file contains the implementation of the HTML Output Handler plugin
# for the course processor.
#
# @author  Chris Page &lt;chris@starforge.co.uk&gt;
# @version 3.0
# @date    11 Nov 2010
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

use strict;
use base qw(Plugin); # This class extends Plugin

use Cwd qw(getcwd chdir);
use MIME::Base64;
use URI::Encode qw(uri_encode);
use Utils qw(check_directory resolve_path load_file save_file lead_zero);


# The location of htmltidy, this must be absolute as we can not rely on path being set.
use constant DEFAULT_TIDY_COMMAND => "/usr/bin/tidy";

# The commandline arguments to pass to htmltidy when cleaning up output.
use constant DEFAULT_TIDY_ARGS    => "-i -w 0 -b -q -c -asxhtml --join-classes no --join-styles no --merge-divs no";

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
    
    # Set defaults in the configuration if values have not been provided.
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidycmd"}    = DEFAULT_TIDY_COMMAND if(!defined($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidycmd"}));
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidyargs"}   = DEFAULT_TIDY_ARGS    if(!defined($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidyargs"}));
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidybackup"} = DEFAULT_BACKUP       if(!defined($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidybackup"}));
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidy"}       = DEFAULT_TIDY         if(!defined($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidy"}));
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
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"} = path_join($self -> {"config"} -> {"path"},"templates",$self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"}) 
        if($self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"} !~ /^\//);

    # Force the path to be absolute in all situations
    $self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"} = resolve_path($self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"});

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "HTMLOutputHandler using template directory : ".$self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"});

    # Make sure the directory actually exists
    check_directory($self -> {"config"} -> {"HTMLOutputHandler"} -> {"templates"}, "HTMLOutputHandler template directory");

    # if we get here, we can guarantee to be able to use the plugin.
    return 1;
}


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
    $self -> write_glossary_pages();
    $self -> {"refhandler"} -> write_reference_page()
        if($self -> {"refhandler"});

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Preprocessing complete");

    # Go through each theme defined in the metadata, processing its contents into 
    # the output format.
    foreach my $theme (keys(%{$self -> {"mdata"} -> {"themes"}})) {

        # Skip themes that should not be included
        if($self -> {"filter"} -> exclude_resource($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"})) {
            $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Theme $theme excluded by filtering rules.");
            next;
        }

        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing $theme");

        # Confirm that the theme is a directory, and check inside for subdirs ($theme is a theme, subdirs are modules)
        my $fulltheme = path_join($self -> {"config"} -> {"Processor"} -> {"outdir"}, $theme);
        if(-d $fulltheme) {

            # Now we need to get a list of modules inside the theme. This looks at the list of modules 
            # stored in the metadata so that we don't need to worry about non-module directoried...
            foreach my $module (keys(%{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"}})) {

                # Determine whether the module will be included in the course
                if($self -> {"filter"} -> exclude_resource($self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"} -> {$module})) {
                    $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Module $theme excluded by filtering rules.");
                    next;
                }

                $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing $module ($fulltheme/$module)");

                my $fullmodule = path_join($fulltheme, $module); # prepend the module directory...

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
                            next;
                        }

                        $self -> process_step($theme, $module, $stepid, $maxstep);
                        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Finished processing $module ($fulltheme/$module)");
                    }
                    chdir($cwd);

                    $self -> cleanup_module($fullmodule);
                } # if(-d $fullmodule) 

                $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing index files");
                $self -> write_theme_indexmap($fulltheme, $theme, $metadata, $include);

            } else { # if($metadata && ($metadata != 1)) {
                $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Skipping directory $fulltheme: no metadata in directory");
            }
        } # if(-d $fulltheme) {
    } # foreach my $theme (@themes) {

    $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "HTMLOutputhandler processing complete");

    closedir(SRCDIR);

    $self -> write_courseindex($srcdir, $self -> {"fullmap"});
    $self -> framework_merge($srcdir, $frame);

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
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Unable to locate anchor $anchor. Link text is '$text' in $module step $stepid");
        return '<span class="error">'.$text.' (Unable to locate anchor '.$anchor.')</span>';
    }

    my $backup = $level eq "step" ? "../../" : $level eq "theme" ? "../" : die "FATAL: Illegal level specified in convert_link. This should not happen.\n";
    
    return "<a href=\"".$backup.$targ -> {"theme"}."/".$targ -> {"module"}."/step".lead_zero($targ -> {"step"}).".html#$anchor\">$text</a>";
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
        return $self -> load_template("glossary/index-active.tem"    , { "***letter***" => uc($letter) });
    } elsif($entries && (scalar(@$entries) > 0)) {
        return $self -> load_template("glossary/index-indexed.tem"   , { "***letter***" => uc($letter),
                                                                         "***link***"   => $link});        
    } else {
        return $self -> load_template("glossary/index-notindexed.tem", { "***letter***" => uc($letter) });            
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
# @param letter   The letter that all terms on the page should start with (either a 
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
    save_file(path_join($outdir, $filename), $self -> {"template"} -> load_template("glossary/entrypage.tem",
                                                                                    {"***title***"        => $title,
                                                                                     "***glosrefblock***" => $self -> build_glossary_references("glossary"),
                                                                                     "***include***"      => $self -> {"mdata"} -> {"course"} -> {"extrahead"},
                                                                                     "***index***"        => $self -> build_glossary_indexbar($letter, $charmap),
                                                                                     "***breadcrumb***"   => $self -> {"template"} load_template("glossary/breadcrumb-content.tem",
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
    if(!$terms) {
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
    my @termlist = sort(keys(%$self -> {"terms"}));

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
                                                                                        "***include***"      => $self -> {"mdata"} -> {"course"} -> {"extrahead"},
                                                                                        "***index***"        => $self -> build_glossary_indexbar("", $charmap),
                                                                                        "***breadcrumb***"   => $self -> {"template"} load_template("glossary/breadcrumb-indexonly.tem"),
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
         foreach my $step (sort numeric_order keys(%{$metadata -> {"module"} -> {$module} -> {"step"}})) {
            $steps .= load_complex_template($self -> {"templatebase"}."/theme/index_step.tem",
                                            {"***url***"   => "$module/".get_step_name($step),
                                             "***title***" => $metadata -> {"module"} -> {$module} -> {"step"} -> {$step}});
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
                                          "***title***" => $metadata -> {$theme} -> {"theme"} -> {"module"} -> {$entry} -> {"title"}});
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
                                  if(!$metadata -> {$theme} -> {"module"} -> {$a} -> {"indexorder"} or !$metadata -> {$theme} -> {"theme"} -> {"module"} -> {$b} -> {"indexorder"});
                              defined($metadata -> {$theme} -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"}) ?
                                  $metadata -> {$theme} -> {"theme"} -> {"module"} -> {$a} -> {"indexorder"} <=> $metadata -> {$theme} -> {"module"} -> {$b} -> {"indexorder"} :
                                  $a cmp $b; 
                            }
                            keys(%{$metadata -> {$theme} -> {"theme"} -> {"module"}});

        my $modbody = "";

        # For each module, build a list of steps and interlinks.
        foreach my $module (@modnames) {
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Module: $module = ".$metadata -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"title"});

            # skip dummy modules
            next if($module eq "dummy" || $metadata -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"skip"});

            my ($prereq, $leadsto, $steps) = ("", "", "");

            # build the prerequisites and leadsto links for the module
            # Prerequisites first...
            my $entries = $metadata -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"prerequisites"} -> {"target"};
            if($entries) {
                $prereq = load_complex_template($self -> {"templatebase"}."/courseindex-module-prereqs.tem",,
                                                {"***prereqs***" => $self -> build_courseindex_deps($entries, $metadata, $theme)});
            }

            # ... then the leadstos...
            $entries = $metadata -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"leadsto"} -> {"target"};
            if($entries) {
                $leadsto = load_complex_template($self -> {"templatebase"}."/courseindex-module-leadsto.tem",
                                                 {"***leadsto***" => $self -> build_courseindex_deps($entries, $metadata, $theme)});
            }
        
            # ... and then the steps.
            foreach my $step (sort numeric_order keys(%{$metadata -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"step"}})) {
                $steps .= load_complex_template($self -> {"templatebase"}."/courseindex-step.tem",
                                                {"***url***"   => "$theme/$module/".get_step_name($step),
                                                 "***title***" => $metadata -> {$theme} -> {"module"} -> {$module} -> {"step"} -> {$step}});
            }

            # finally, glue them all together.
            $modbody .= load_complex_template($self -> {"templatebase"}."/courseindex-module.tem",
                                              {"***title***"      => $metadata -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"title"},
                                               "***name***"       => "$theme-$module",
                                               "***stepurl***"    => "$theme/$module/step01.html",
                                               "***level***"      => $metadata -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"level"},
                                               "***difficulty***" => ucfirst($metadata -> {$theme} -> {"theme"} -> {"module"} -> {$module} -> {"level"}),
                                               "***prereqs***"    => $prereq,
                                               "***leadsto***"    => $leadsto,
                                               "***steps***"      => $steps});
        } # foreach my $module (@modnames) {
        
        # Shove the module into a theme...
        $body .= load_complex_template($self -> {"templatebase"}."/courseindex-theme.tem",
                                       {"***name***"    => $theme,
                                        "***title***"   => $metadata -> {$theme} -> {"theme"} -> {"title"},
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
                                                                      "***title***" => $layout -> {$theme} -> {"theme"} -> {"title"}});

        $themedrop_module .= $self -> {"template"} -> load_template("theme/module/themedrop-entry.tem",
                                                                    { "***name***"  => $theme,
                                                                      "***title***" => $layout -> {$theme} -> {"theme"} -> {"title"}});
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
# @note This will die if any module is missing its indexorder (although this should
#       not happen if the metadata was validated during loading)
#
# @param theme The name of the theme to generate the module dropdown for.
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
    foreach $theme (@$themenames) {
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
    return unless($self -> {"config"} -> {"Processor"} -> {"debug"});

    my $out = `rm -fv $moddir/node*.html`;
    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Cleanup output:\n$out");
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
            foreach my $module (keys(%{$self -> {"mdata"} -> {"themes"} -> {$theme} -> {"theme"} -> {"module"}})) {
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

                        my @sortedsteps = sort step_sort @steps;

                        my $outstep = 0;
                        foreach my $step (@sortedsteps) {
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
                                or die "FATAL: Unable to open step file '$fullmodule/$step': $!\n";

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
                                $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Recording $title step as $theme -> $module -> steps -> $step");
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
            closedir(MODDIR);
        } # if(-d $fulltheme)
    } # foreach my $theme (@themes)

    closedir(SRCDIR);
    
    $self -> build_dropdowns();

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Finished preprocesss");
}


# ============================================================================
#  Step processing and tag conversion code.
#  
 
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
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Image tag attribute list does not include name");
        return "<p class=\"error\">Image tag attribute list does not include name</p>";
    }

    # Work out the alignment class for the image
    my $divclass = "floatleft";
    if($attrs{"align"}) {
        if($attrs{"align"} =~ /^left$/i) {
            $divclass = "floatleft";
        } elsif($attrs{"align"} =~ /^right$/i) {        
            $divclass = "floatright";
        } elsif($attrs{"align"} =~/^center$/i) {
            $divclass = "center";
        }
    }

    # The image style deals with width, height, and other stuff...
    my $imgstyle = "border: none;";
    $imgstyle .= " width: $attrs{'width'};"   if($attrs{"width"});
    $imgstyle .= " height: $attrs{'height'};" if($attrs{"height"});

    return load_complex_template($self -> {"templatebase"}."/theme/module/image.tem",
                                 {"***name***"     => $attrs{"name"},
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
    my ($title) = $args =~ /title="([^"]+)"/si;

    # Other arguments are discarded in this version as they no longer have any real meaning.

    return $self -> load_template("theme/module/popup.tem",
                                  {"***title***" => $title,
                                   "***body***"  => encode_base64($data),
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
    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing out processed data to ".get_step_name($filename));
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
                                                      "***prevlink***"      => $prevlink,
                                                      "***nextlink***"      => $nextlink,
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
                                                      "***glosrefblock***"  => $self -> build_glossary_references("theme/module"),
                                                      "***include***"       => $self -> {"mdata"} -> {"course"} -> {"extrahead"},
                                                      "***version***"       => $self -> {"mdata"} -> {"course"} -> {"version"},
                                                     }))
        or die "FATAL: Unable to write to ".get_step_name($stepid).": $!\n";

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing complete");

    # Try to do tidying if the tidy mode has been specified and it exists
    if($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidy"}) {
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Tidying ".get_step_name($stepid));

        die "FATAL: Unable to run htmltidy: tidy does not exist at ".$self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidycmd"}."\n"
            if(-e $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidycmd"});

        my $name = get_step_name($stepid);

        # make a backup if we're running in debug mode
        `cp -f $name $name.orig` if($self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidybackup"});

        # Now invoke tidy
        my $cmd = $self -> {"config"}-> {"HTMLOutputHandler"} -> {"tidycmd"}." ".
            $self -> {"config"} -> {"HTMLOutputHandler"} -> {"tidyargs"}." -m $name";
        
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Invoing tidy using: $cmd");
        my $out = `$cmd 2>&1`;

        # Echo the output if needed so that debugging of tidy is doable.
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Tidy output: $out");
    }
    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Step processing complete");
}

1;
