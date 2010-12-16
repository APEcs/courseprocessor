## @file
# This file contains the implementation of the HTML Input Handler plugin
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

## @class HTMLInputHandler
# This plugin class allows a hierarchy of HTML files to be converted into
# the processor's intermediate format. It expects the HTML files to be
# structured in the standard APEcs course directory hierarchy:
#
# coursedata/
#    theme1/
#        module1/
#            name01.html
#            name02.html
#            name03.html
#        module2/
#            name01.html
#            name02.html
#            name03.html
# ...etc...
#
# This plugin will take the html files in the tree and perform any tag
# substitutions and content checks necessary, and write out the partially
# processed html to the intermediate format.
package HTMLInputHandler;

use strict;
use base qw(Plugin); # This class extends Plugin

use Cwd qw(getcwd chdir);
use Digest::MD5 qw(md5_hex);
use File::Path qw(make_path);
use ProgressBar;
use Utils qw(path_join load_file);


# The location of the latex processor, must be absolute, as the path may have been nuked.
use constant DEFAULT_LATEX_COMMAND => "/usr/bin/latex2html";

# The default header to use if none had been provided by the user
use constant DEFAULT_LATEX_HEADER  => "\\documentclass[12pt]{article}\n\\usepackage{html}\n\\usepackage[dvips]{color}\n\\pagecolor{white}";

# The arguments to pass to the latex processor
use constant DEFAULT_LATEX_ARGS    => '-nonavigation -noaddress -white -noinfo -antialias_text -html_version "4.1"';

# Should temporary files be removed?
use constant DEFAULT_CLEANUP       => 1;

# File pattern for matching operations
use constant FILE_REGEXP           => '[\s\w-]+\d+\.html?';

# Plugin basic information
use constant PLUG_TYPE             => 'input';
use constant PLUG_DESCRIPTION      => 'HTML input processor';


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
    
    $self -> {"extfilter"}   = FILE_REGEXP;

    # Set defaults in the configuration if values have not been provided.
    $self -> {"config"} -> {"HTMLInputHandler"} -> {"latexcmd"}   = DEFAULT_LATEX_COMMAND if(!defined($self -> {"config"} -> {"HTMLInputHandler"} -> {"latexcmd"}));
    $self -> {"config"} -> {"HTMLInputHandler"} -> {"latexargs"}  = DEFAULT_LATEX_ARGS if(!defined($self -> {"config"} -> {"HTMLInputHandler"} -> {"latexargs"}));
    $self -> {"config"} -> {"HTMLInputHandler"} -> {"latexintro"} = DEFAULT_LATEX_HEADER if(!defined($self -> {"config"} -> {"HTMLInputHandler"} -> {"latexintro"}));
    $self -> {"config"} -> {"HTMLInputHandler"} -> {"cleanup"}    = DEFAULT_CLEANUP if(!defined($self -> {"config"} -> {"HTMLInputHandler"} -> {"cleanup"}));

    return $self;
}


## @method $ use_plugin()
# Determine whether this plugin should be run against the source tree by looking for
# files it recognises how to process in the directory structure. This will scan 
# through the directory structure of the source and count how many files it thinks
# the plugin should be able to process, and returns this count. If this is 0, the
# plugin can not be used on the source tree.
#
# @return The number of files in the source tree that the plugin can process, 0
#         indicates that the plugin can not run on the source tree.
sub use_plugin {
    my $self   = shift;

    # This gets set > 1 if there are any files this plugin understands, and it can be used
    # during processing to show the progress of processing.
    $self -> {"filecount"} = 0; 

    # This should be the top-level "source data" directory, should contain theme dirs
    opendir(SRCDIR, $self -> {"config"} -> {"Processor"} -> {"datasource"})
        or die "FATAL: Unable to open source directory (".$self -> {"config"} -> {"Processor"} -> {"datasource"}.") for reading: $!";

    # grab the directory list so we can check it for subdirs, strip .* files though
    my @srcentries = grep(!/^\./, readdir(SRCDIR));
    
    foreach my $theme (@srcentries) {
        $theme = path_join($self -> {"config"} -> {"Processor"} -> {"datasource"}, $theme); # prepend the source directory

        # if this is a directory, check inside for subdirs ($entry is a theme, subdirs are modules)
        if(-d $theme) {
            opendir(MODDIR, $theme)
                or die "FATAL: Unable to open source module directory $theme for reading: $!";

            # Obtain the list of files and direcories without dotfiles
            my @modentries = grep(!/^\./, readdir(MODDIR));

            # Process all the files and dirs in the theme directory.
            foreach my $module (@modentries) {
                $module = path_join($theme, $module); # prepend the module directory...

                # If this is a module directory, we want to scan it for steps
                if(-d $module) {
                    opendir(SUBDIR, $module)
                        or die "FATAL: Unable to open source subdir for reading: $!";
            
                    # grep returns the number of matches in scalar mode and that's all we
                    # really want to know at this point
                    $self -> {"filecount"} += grep(/^$self->{extfilter}$/, readdir(SUBDIR));

                    closedir(SUBDIR);
                }

            } # foreach my $module (@modentries) {

            closedir(MODDIR);

        } # if(-d $theme) { 
    } # foreach my $theme (@srcentries) {

    closedir(SRCDIR);

    return $self -> {"filecount"};
}


# @method $ module_check($themedir, $module)
# Check whether the module specified is valid and usable by this plugin. This is
# used by the metadata validation code to determine whether the module specified
# appears to be valid. This will return a string containing an error message if 
# there is a problem, 0 otherwise.
#
# @param themedir The directory containing the module to check.
# @param module   The name of the module to check.
# @return 0 if the module is valid, an error string otherwise.
sub module_check {
    my $self     = shift;
    my $themedir = shift;
    my $module     = shift;

    # does the directory for the specified module exist?
    return "HTMLInputHandler: Module $module does not have a corresponding module directory." unless(-e path_join($themedir, $module));

    # ensure it is a directory, not a file
    return "HTMLInputHandler: $themedir/$module is a normal file or symlink, not a directory." unless(-d path_join($themedir, $module));

    # is it readable? We just have to hope the files inside are too...
    return "HTMLInputHandler: $themedir/$module is not readable." unless(-r path_join($themedir, $module));

    # if we get here, it's okay.
    return 0;
}


## @method $ process()
# Run the plugin over the contents of the course data. This will process all 
# html in the course directory into the intermediate data format ready for
# processing by an output handler.
sub process {
    my $self = shift;

    # Attempt to load the latex header from the course metadata. Fall back on the predefined
    # latex header if the header is not specified in the metadata.
    my $course = $self -> {"metadata"} -> load_metadata($self -> {"config"} -> {"Processor"} -> {"outputdir"}, "course", 1);
    if(ref($course) && $course -> {"course"} -> {"latexintro"}) {
        $self -> {"latexintro"} = $course -> {"course"} -> {"latexintro"};
    } else {
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "latexintro element not specified in course metadata, falling back on default.");
    }

    # ensure we have output dirs we need
    $self -> check_media_dirs();

    # This should be the top-level "source data" directory, should contain theme dirs
    opendir(SRCDIR, $self -> {"config"} -> {"Processor"} -> {"outputdir"})
        or die "FATAL: Unable to open source directory (".$self -> {"config"} -> {"Processor"} -> {"outputdir"}.") for reading: $!";

    # grab the directory list so we can check it for subdirs, strip .* files though
    my @srcentries = grep(!/^\./, readdir(SRCDIR));

    # Display progress if needed...
    $self -> {"progress"} = ProgressBar -> new(maxvalue => $self -> {"filecount"},
                                               message  => "Processing html files...")
        if(!$self -> {"config"} -> {"Processor"} -> {"quiet"} && $self -> {"config"} -> {"Processor"} -> {"verbosity"} == 0);
    my $processed = 0;

    # Go through all the directory entries, processing each one
    foreach my $theme (@srcentries) {
        $theme = path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, $theme); # prepend the source directory

        # if this is a directory, check inside for subdirs ($entry is a theme, subdirs are modules)
        if(-d $theme) {
            opendir(THEMEDIR, $theme)
                or die "FATAL: Unable to open theme directory $theme for reading: $!";

            my @modentries = grep(!/^\./, readdir(THEMEDIR));

            foreach my $module (@modentries) {
                $module = path_join($theme, $module); # prepend the module directory...

                # If this is a module directory, we want to scan it for steps
                if(-d $module) {
                    opendir(STEPS, $module)
                        or die "FATAL: Unable to open module directory $module for reading: $!";
            
                    # Know grab a list of files we know how to process
                    my @subfiles = grep(/^$self->{extfilter}$/, readdir(STEPS));

                    if(scalar(@subfiles)) {
                        my $cwd = getcwd();
                        chdir($module);

                        # obtain the sorted files
                        my ($stepfiles, $numlength) = $self -> sort_step_files(\@subfiles);
                        
                        # for each file we know how to process, pass it to the html processor
                        # to be converted. 
                        for(my $i = 0; $i < scalar(@$stepfiles); ++$i) { 
                            $self -> process_html_page($stepfiles -> [$i], $i, $numlength, $self -> {"config"} -> {"Processor"} -> {"outputdir"}, $module);

                            # Update the progress bar if needed
                            $self -> {"progress"} -> update(++$processed) if($self -> {"progress"});
                        }

                        # Remove files we don't need from the module directory.
                        $self -> cleanup() if($self -> {"config"} -> {"HTMLInputHandler"} -> {"cleanup"});

                        chdir($cwd);
                    } # if(scalar(@subfiles)) {

                    closedir(STEPS);
                } # if(-d $module) {
            } # foreach my $module (@modentries) {

            closedir(THEMEDIR);

        } # if(-d $theme) {
    } # foreach my $theme (@srcentries) {

    closedir(SRCDIR);

    return 1;
}


# ============================================================================
#  File handling code
#   

## @method void check_media_dirs()
# Ensure that the required media directory is present on the filesystem This is
# somewhat wasteful if the processing results in no latex image generation
# events, but it probably isn't worth any complex code to avoid it.
sub check_media_dirs {
    my $self = shift;

    if(!-e path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, "media")) {
        make_path(path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, "media"))
            or die "FATAL: Unable to create media directory: $!\n";
    }

    if(!-e path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, "media", "generated")) {
        make_path(path_join($self -> {"config"} -> {"Processor"} -> {"outputdir"}, "media", "generated"))
            or die "FATAL: Unable to create generated media directory: $!\n";
    }
}


## @method $ fix_quotes($tag, $body)
# Converts &quot symbols on the specified body text to literal quotes. Should 
# be used to convert the contents of tag attribute lists to the correct form. 
# This will also ensure that newlines in quotes are removed (Dreamweaver wordwrap 
# workaround)
#
# @param tag  The tag name.
# @param body The contents of the tag.
# @return The tag with fixed quotes and removed newlines.
sub fix_quotes {
    my $self = shift;
    my $tag  = shift;
    my $body = shift;

    # convert quote entities to literals
    $body =~ s/&quot;/\"/go;

    # remove newlines in quoted blocks
    $body =~ s/"(.*?)\s*?\n\s*(.*?)"/"$1 $2"/g;

    return "[$tag $body]";
}
 

# Converts local inter-theme or inter-module links to a form that will work when
# the course content has been passed through the output handler
sub fix_anchor_links {
    my $self     = shift;
    my $prelink  = shift;
    my $link     = shift;
    my $postlink = shift;

    # pull out the path, step number and anchor from the link
    my ($path, $step, $anchor) = $link =~ m|((?:../)+(?:.*?/)+)\D+(\d+(?:.\d+)?).html?\#(.*?)|i;

    # rebuild the anchor link and return it
    return '<a'.$prelink.'href="'.$path."step$step.html\#$anchor\"$postlink>";
}


## @method $ read_html_file($filename)
# Load the contents of a html file, stripping out the title and body and
# discarding any non-general content (ie: no templates or CBT specific
# content is passed through, only the actual text and images of the step.)
#
# @param filename The name of the file to load into memory.
# @return An array of two items: the page title, and the contents of the body.
sub read_html_file {
    my $self = shift;
    my $filename = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Reading contents of $filename.");
    
    # First we need to grab the file text itself...
    my $data = load_file($filename);
    
    # Die immediately if the file load failed.
    return (undef, undef) if(!$data);

    # Now grab the title and body, the rest can be binned
    my ($title, $body) = $data =~ m|<title>(.*?)</title>.*<body.*?>\s*(.*?)\s*</body>|ios;

    # Can't parse, drop out with an error
    die "FATAL: Unable to parse body from $filename Giving up." if(!$body);

    # now try to pull out the body content...
    # New template format: we have a <div id="content">...</div><!-- id="content" -->
    if($body =~ m|<div id="content">\s*(.*?)\s*</div>\s*<!-- id="content" -->|ios) {
        $body = $1;
        $self ->{"logger"} -> print($self -> {"logger"} -> DEBUG, "Body is in new template content format.");

    # Emergency catch case for the new templates, needed in case the body has been 
    # defined incorrectly, but is far riskier when applied to popups.
    } elsif($body =~ m|<div id="content">\s*(.*?)\s*</div>\s*$|ios) {
        $body = $1;
        $self ->{"logger"} -> print($self -> {"logger"} -> DEBUG, "Body is in new template content format, unterminated content div.");

    # Old template format
    } elsif($body =~ m|<div id="content">\s*<div>&nbsp;</div>\s*(.*)\s*<div style="clear: both">&nbsp;</div>\s*</div>\s*<!-- <div id="content"> -->|ios){
        $body = $1;
        $self ->{"logger"} -> print($self -> {"logger"} -> DEBUG, "Body is in old template content format.");

    # Original body format...
    } elsif($body =~ m|^\s*<center>\s*<table .*?>\s*<tr>\s*<td>\s*(.*?)\s*</td>\s*</tr>\s*</table>\s*</center>\s*$|ios) {
        $body = $1;
        $self ->{"logger"} -> print($self -> {"logger"} -> DEBUG, "Body is in original content format.");

    # Unknown, give up
    } else {
        $self ->{"logger"} -> print($self -> {"logger"} -> DEBUG, "Body of $filename is in unknown format, passing through. Expect breakage.");
    }

    # backconvert tag-enclosed &quot;s
    foreach my $tag ("glossary", "img", "anim", "applet", "local", "link", "target") {
        # convert quote entities to literal quotes
        $body =~ s/\[$tag\s+(.*?)\]/$self -> fix_quotes($tag, $1)/isge;
    }
        
    return ($title, $body);
}
    

## @method $ read_latex_file($latexdir, $checksum, $offset)
# Extract the body from a generated latex file, replacing any images with
# names intended to be unique to specific content.
#
# @param latexdir The directory containing the latex2html output files.
# @param checksum The checksum of the latex used to provide uniqueness for images.
# @param offset   The relative path offset to the media directory, needed as we 
#                 can't use an absolute path to the media directory.
# @return The body of the generated latex file.
sub read_latex_file {
    my $self     = shift;
    my $latexdir = shift;
    my $checksum = shift;
    my $offset   = shift;

    # Load the generated content, hopefully it'll always end up in node2.
    my $content = load_file("$latexdir/node2.html");
    die "FATAL: Unable to read content from $latexdir/node2.html: $!\n This Should Not Happen! Check the output from latex2html to determine why this\nfailed. In particular, check for things like nested \$s in maths blocks." if(!$content);
    
    # extract the body...
    my ($body) = $content =~ /<body.*?>\s*(.*?)\s*(?:<br>)?\s*<hr>\s*<\/body>/si;
    die "FATAL: Unable to read body from $latexdir/node2.html. This Should Not Happen" if(!$body);

    # ... and strip the inline title if it exists
    $body =~ s/\s*<h\d><a name=".*?">.*?<\/a>\s*<\/h\d>\s*//si;

    # Now we need to convert any images
    $body =~ s/src="img(\d+)\.(\w+)"/src="${offset}\/media\/generated\/$checksum-img$1.$2"/gi;

    return $body;
}


## @fn $ sort_step_func()
# Sort filenames based on the first number in the name, discarding all letters.
#
# @return The numeric comparison of the first numbers encountered in the
#         filenames in $a and $b
sub sort_step_func {
    
    # obtain the *FIRST NUMBER IN THE FILENAME*
    my ($anum) = $a =~ /^[a-zA-Z_-]*(\d+)/o;
    my ($bnum) = $b =~ /^[a-zA-Z_-]*(\d+)/o;

    # numeric comparison should remove the need for zero-padding that would be needed for alphanumeric
    return $anum <=> $bnum;
}



# Give an unsorted list of files, this will generate a sorted array of files
# such that the array index may be used to determine the number of the target 
# file (except for the need to +1 to the index). Returns a reference to the
# sorted array and the numbe rof characters the digits part of a step name 
# should contain.
sub sort_step_files {
    my $self      = shift;
    my $filenames = shift;

    # sort the files, and then fall over if the step count exceeds 99
    my @sortfiles = sort sort_step_func @$filenames; 
    die "FATAL: step count limit exceeded. Modules must not contain more than 99 steps" if(scalar(@sortfiles) > 99);
    
    # we can fix the step number count at 2, this should ensure leading-0s 
    # across the whole course.
    return (\@sortfiles, 2);
}

# ============================================================================
#  Tag support code
#   

# mark latex tags inside glossary definitions
sub mark_glossary_latex {
    my $self = shift;
    my $term = shift;
    my $body = shift;

    $body =~ s/\[latex\]/\[latex glossary\]/gi;

    return '[glossary term="'.$term.'"]'.$body."[/glossary]";
}


# convert a remote linked local tag to an in-document local tag
sub read_local_tag {
    my $self     = shift;
    my $term     = shift;
    my $filename = shift;
    my $extra    = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Got local tag replacement for $term, content is in $filename");

    # Load the body of the popup (we don't actually care about the title here)
    my ($title, $body) = $self -> read_html_file($filename);

    # give up if the popup file body can't be loaded
    if(!$body) {
        $self -> {"logger"} -> print($self -> {"logger"} -> NOTICE, "Unable to read popup file ".$filename.": $!");
        return '<span class="error">Unable to read popup file '.$filename.": $!</span>";
    }

    # IMPORTANT: DO NOT attempt to delete $filename at this point. While it would
    # make deletion neater (we'd only have to nuke processed files rather than
    # take out /all/ non-nodeN.html html files) it is possible that popup files may
    # be shared across steps and removing the file for the first hit will break
    # later references to it.

    # If we have a body, return a tag with the contents of the file in the popup 
    my $output = '[local text="'.$term.'"';
    $output .= " $extra " if(defined($extra) && $extra);
    $output .= ']'.$body.'[/local]';

    return $output;
}


# Convert a block of LaTeX code into html and return the body of the generated
# content. If the processing fails for some reason the latex is replaced by
# an error message in the code, unfortunately it would be too complex to 
# snarf the true error from the latex2html output so we just drop in an error
# and let the use look up the real problem in the log.
sub process_latex {
    my $self     = shift;
    my $content  = shift;
    my $base     = shift;
    my $glossary = shift;
    my $filename = shift;

    $glossary = 0 if(!defined($glossary));

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing latex content \"$content\" in step $filename");

    my $body = '<span class="error">Failed to proces latex directive</span>';

    # work out what to call the temporary file. Uses the md5 of the 
    # content to determine the filename extension (nice side effect: two
    # graphics-generating latex block in the same module will end up sharing
    # images thanks to this)
    my $checksum = md5_hex($content);
    $checksum .= "g" if($glossary);
    my $tempname = "/tmp/htmlinput-$checksum.tex";

    # If we have already processed this latex block somewhere else in the course, use
    # the cached version rather than invoking latex2html and doing postprocessing again
    if($self -> {"latexcache"} -> {$checksum}) {
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "latexcache hit for content, md5 $checksum");
        return $self -> {"latexcache"} -> {$checksum};

    } else {
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "latexcache miss for content, md5 $checksum");

        # attempt to open the temporary file and write the content to it.
        if(open(TMPFILE, ">:utf8", $tempname)) {
            print TMPFILE $self -> {"config"} -> {"HTMLInputHandler"} -> {"latexintro"};
            print TMPFILE "\n\n\\begin{document}\n";
            print TMPFILE "\\section{autogenerated}\n\\subsection{autogenerated}\n";
            print TMPFILE $content;
            print TMPFILE "\n\\end{document}\n";
            close(TMPFILE);
            
            # Now run latex2html on it
            my $cmd = $self -> {"config"} -> {"HTMLInputHandler"} -> {"latexcmd"}." ".$self -> {"config"} -> {"HTMLInputHandler"} -> {"latexargs"}." ".$tempname;
            
            my $output = `$cmd 2>&1`;
            if($output =~ /Error while converting image/) {
                print $output;
                die "FATAL: Errors encountered while running latext2html";
            }
            
            print $output if($self -> {"verbose"} > 1);

            # before we can process the content we need the name without the .tex extension
            $tempname = "/tmp/htmlinput-$checksum";

            # Grab the autogenerated content
            $body = $self -> read_latex_file($tempname, $checksum, $glossary ? ".." : "../..");
            
            # Move any images across from the latex2html generated directory to the 
            # course global generated directory
            while(my $name = glob("/tmp/htmlinput-$checksum/img*.png")) {
                $name =~ /img(\d+)\.(\w+)/;
                
                my $dest = "$base/media/generated/$checksum-img$1\.$2";

                $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Copying and cropping $name as $dest");
                # old move: `mv -f $name $dest`;

                # the following line theoretically removes spurious bottom black bars
                # hopefully this won't screw up real boxing...
                `pngtopnm $name | pnmcrop -black | pnmtopng -transparent "#B3B3B3" > $dest`;
            }

            # Remove the generated content
            `rm -rf $tempname`;
            
            # remove the source latex file
            `rm -f $tempname.tex`;

            # store the body in the cache
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Caching processed body for $content, md5 $checksum");
            $self -> {"latexcache"} -> {$checksum} = $body;

            return $body;
        } else { # if(open(TMPFILE, "> $tempname")) {
            # temporary file open failed, return an error.
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Unable to open temporary latex file ".$tempname.": $!\n");
            return '<span class="error">Unable to open temporary latex file '.$tempname.": $!</span>";
        }
    } # if($self -> {"latexcache"} -> {$checksum}) { ... } else {
}


# ============================================================================
#  Process code
#   

# remove any non-node .html files from the output directory, leaves other formats
# intact as we don't know what support files the user has placed in the same directory.
sub cleanup {
    my $self = shift;

    # obtain the current directory listing
    my @files = glob("./*");

    # only bother with files enging in .html/.htm
    # FIXME: this could probably be optimised with the correct filter to the glob, or
    # by using readdir/grep, but it seems to work well enough for now.
    foreach my $filename (@files) {
        if(($filename =~ /\.html?$/) && ($filename !~ /^.\/node\d+\.html$/)) {
            $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Removing source file \"$filename\"");            
            unlink $filename;
        }
    }
            
}

# Convert an individual html page into the intermediate format used by the course processor,
# bringing in the contents of any popups in the process.
sub process_html_page {
    my $self     = shift;
    my $filename = shift;
    my $index    = shift;
    my $count    = shift;
    my $base     = shift;
    my $reldir   = shift;

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Processing html file \"$filename\"");

    my ($title, $body) = $self -> read_html_file($filename);

    # give up if no body can be obtained from the file (shouldn't happen unless the html 
    # is badly malformed, otherwise there should always be /some/ body returned, even if
    # if includes extraneous material we don't really want.
    if(!$body) {
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Unable to load $filename: $!");
        return;
    }

    $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "No title found in $filename") if(!$title);

    # popup reverse engineering.
    $body =~ s|<a href="javascript:OpenPopup('(.*?)', 'ContentPopup', (\d+), (\d+))">(.*?)</a>|$self -> read_local_tag($2, $1, "width=\"$1\" height=\"$2\"")|iesg;
    $body =~ s|\[local text="([^\]]?)" src="(.+?)"\s*(.*?)\s*\/?\]|$self -> read_local_tag($1, $2, $3)|iesg;

    # link correction
    $body =~ s|<a(.*?)href="((../)+(.*?/)+\D+(\d+(.\d+)?).html?#(.*?))"(.*?)>|$self -> fix_anchor_links($1, $2, $8)|iesg;

    # mark latex inside glossary tags
    $body =~ s|\[glossary\s+term="(.+?)"\](.+?)\[/glossary\]|$self -> mark_glossary_latex($1, $2)|iesg;

    # latex processing
    $body =~ s|\[latex\s*(glossary)?\](.*?)\[/latex\]|$self -> process_latex($2, $base, $1, "$reldir/$filename")|iesg;

    my $destname =  sprintf("node%0${count}d.html", $index + 1);

    # Attempt to write the intermediate format file.
    if(open(OUTFILE, ">:utf8", $destname)) {
        $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "Writing processed contents of \"$filename\" to \"$destname\"");
        
        print OUTFILE "<html>\n<head>\n<title>",$title,"</title>\n</head>\n\n";
        print OUTFILE "<body>\n",$body,"\n</body>\n</html>\n";
        close(OUTFILE);
    } else {
        $self -> {"logger"} -> print($self -> {"logger"} -> WARNING, "Unable to open node$1.html for writing: $!");
    }

    $self -> {"logger"} -> print($self -> {"logger"} -> DEBUG, "\"$filename\" processing complete");
}

1;
