Course Processor Documentation
$Id$

Contact: chris@starforge.co.uk
Bugs: http://octette.cs.man.ac.uk/bugzilla/


1. Introduction

The course processor is a modular, perl-based text processing application 
designed around a series of plugins to maximise its flexibility. The default
distribution provides plugins capable of processing LaTeX and HTML into
HTML structured around the CBT package paradigms that PEVE implement in
their courses. However, the design of the system is such that the potential
input and output formats, and the structure of both, is not enforced by the
software, only the plugins installed or selected at any time.

The documentation for the course processor is split over multiple files: this
file contains general instructions regarding the reqirements of the processor,
its installation, operation, and configuration. Each input and output handler
has a corresponding document (the LatexInputHandler has latex-input.txt,
HTMLOutputHandler has html-output.txt, and so on). 

Content creators who do not wish to use the processor directly may just want
to consult the input and output handler documentation relevant to their needs.
This will generally involve reading one of the -input.txt documents, and the
html-output.txt document.


2. Requirements

The following list contains the minimal software environment required to run the
course procesor. Later revisions of perl modules and external software are 
likely to work, provided they retain backwards compatibility.

- a Linux or Unix (Solaris/*BSD) system of relatively recent vintage. The 
  course processor *will not* run on Windows natively or in Cygwin due to
  techniques used inside it and its dependancies.

- Perl 5.8 or later. Any Perl 5.x version might handle it, but it has only
  been tested on 5.8+

- latex2html 2002.2.1 or later.

- tetex 3 or similar LaTeX compiler

- netpbm 10 or later (earlier versions of netpbm *will not* work correctly)

- The latest versions of the following Perl modules:
      Term::Size
      Time::Local
      File::Spec
      Digest::MD5
      Data::Dumper
      XML::Simple
      Pod::Usage
      File::HomeDir
      Getopt::Long


3. Installing

The course processor software can be installed anywhere, however the directory
structure provided in the distribution must be preserved. That is the directory
containing the processor.pl file must also contain at least the modules and 
plugins directories as well as, optionally, one or more template directories. 


4. Usage

processor.pl [-vl] [--help] [--man] [-o <outputhandler>] [-t <templates>] 
             [-r <refhandler>] -c <coursedata> -f <framework> -d <outputdir>

Required arguments:

--coursedata coursedir, -c coursedatadir

    Sets the course data source directory. This argument is not optional, 
    and the processor will exit with an error if it is not supplied.

--framework frameworkdir, -f frameworkdir

    Specifies the course framework directory. This argument is not optional,
    and the processor will exit with an error if it is not supplied.

--dest outputdir, -d outputdir

    Specifies the name of the directory into which the course should be 
    processed. NOTE: if this directory exists it will be deleted during 
    processing. Take great care to ensure that the output directory does 
    not contain any vital pre-existing data as the processed course will 
    completely overwrite it.

Optional arguments:

--verbose, -v 

    Increase the output verbosity. This may be repeated several times to 
    increase the verbosity level. -v -v -v enables all levels of output, 
    including debug.

--listhandlers, -l

    Lists the available input, output and reference handlers and then exit.

--help, -h, -?

    Print a brief help message and exits.

--man, -m

    Prints the manual page and exits.

--outhandler outputhandler, -o outputhandler

    Overrides the outputhandler specified in the configuration file (if 
    there is one). Note that this must be the full name of an outputhandler 
    loaded by the software and it is case sensitive. Use -l to obtain the 
    list of known handlers for valid values. If this is not specified, and
    the configuration file does not contain a default, then the 

--templates templatedir, -t templatedir

    Overrides the template directory given in the configuration file. This
    is case sensitive and, unless the path is absolute, it is relative to the 
    directory given in the PROCESSOR_HOME environment variable.

--refhandler referencehandler, -r referencehandler

    Overrides the reference handler specified in the configuration file. 
    This is case sensitive and must correspond to a reference handler 
    loaded by the software. Use -l to obtain a list of known handlers for 
    valid values.


5. Configuration

A number of options may be specified in a user-specific configuration file, 
providing defaults for arguments not specified on the command line (if the
corresponding command line argument is specified, the command line takes
priority over the configuration file).

The configuration file consists of section headers followed by one or more 
key-value pairs (the syntax is similar to that used in Windows .ini files, 
or the Samba configuration files). The configuration should be stored in a
file called .courseprocessor.cfg stored in the user's home directory. An 
example configuration file would be:

[outputhandler]
name = HTMLOutputHandler
templates = newtemplates

[referencehandler]
name = IEEEReferenceHandler

[outputhandler] introduces the section in which the settings for the output
plugin are specified. The following variables may be specified in an
outputhandler section:

name       - the name of the outputhandler to use if not specified on the 
             command line.
templates  - the name of the templates to use while generating the course.
             this must correspond to a template directory within the 
             courseprocessor directory.

[referencehandler] begins the section in which the settings for the reference
handler can be specified. The folowing may be specified in the reference
handler section:

name       - the name of the reference handler to use. 

In order to obtain valid values for the name attributes in both sections, 
invoke the processor with the --listhandlers command line argument.


6. Operational overview

The software is split into roughly four pieces: the core code; input handler
plugins; output handler plugins; and reference handler plugins. The core code
- largely contained within the processor.pl script - coordinates the operation
of the processor and invokes the input and output handlers on the course data.
The input handlers are selected automagically by inspecting the source data 
for the course: each input handler is asked to determine whether it is capable
of processing the source data into a standard intermediate format and, if it
is, it will be run on the source data. This means that you do not need to tell
the course processor which input handler plugins it should use on the course
source as it can determine that for itself. If none of the input handlers can
run on the course data then it will exit with an error. If this happens, check
that you have the necessary input handler plugins installed, the correct course 
data dir and the data is in the correct format. Once all of the input handler
plugins have inspected the source and possibly done work on it the output
handler plugin is invoked to do its work. Unlike the input handler plugins 
you generally need to specify which output handler plugin should be used, 
unless there is only one output handler installed in the system. This allows
the processor to be used to generate a variety of output formats by running
it with different output handlers selected. The reference handler plugins are
not invoked directly by the core code but rather by the output handler plugin:
during processing of the intermediate data generated by the input plugins, 
the output handler does a number of special tag substitutions. One of these
allows references to be included in the course data and, when one is
encountered, the output handler passes processing of the reference to a 
reference handler selected by the user. This allows the generated references
to be presented in a number of different styles depending on the reference
handler selected.


7. Course design and content

The remainder of the documentation for the processor is split over serveral 
files, one for each input or output processor. However, it should be noted 
that all the plugins assume that the input data is split into two directories: 
one is the 'coursedata' directory, which contains all the course-specific
content, while the 'framework' directory contains all the course-common
content such as help files, stock images and pages and so on.

One helpful way to view this bifurcation is to view the "coursedata" directory
as the directory containing all the content that should be subject to processing
but should not appear in the final course directly (LaTeX files, source HTML 
files, resource list files, latex header files and so on) while the second, 
"framework" sould contain all the files that need to be copied directly into the
finished course without processing (static images, animations, applets and 
preprepared template-matching html content). The internal structure of these 
directories reflects the structure of the finished course. An example of 
coursedata and framework directories follows:

coursedata/
  animlist.txt         - optional list of animations
  appletlist.txt       - optional list of applets
  anims/               - course-specific animated material 
  Balsa/               - a theme directory
    balsa_1.tex        - a module, see latex-input.html for more details
    balsa_map.jpg      - static content shown in the theme index
    map.inc            - data to include in the theme map, see html-output.txt
    metadata.xml       - the theme metadata, see html-output.txt
    using_balsa.tex    - another module latex file
  Ch_15/               - another theme directory
    processors_map.jpg - static content shown in the theme index
    dependencies/      - a module dir
      intro_1.html     - a html step, see html-input.txt for more information
      armpipe_2.html   - another step       
  images/              - course-specific images
  imagelist.txt        - list of images, see html-output.txt for more info
  latexintro.txt       - LaTeX header, see the latext-input.txt file
  version.txt          - optional version file, see html-output.txt

framework/
  about_course.html        - static content, description of the course
  courseindex.html         - theme navigation index
  css/                     - global template-specific stylesheets
  disclaimer.html          - static disclaimer
  feedback.html            - static documentation
  framework-anims/         - global template-specific animated material
  framework-images/        - global template-specific images
  index.html               - static front page
  javascript/              - global template-specific javascript files
  navigation_modules.html  - static help documentation
  navigation_start.html    - static help documentation
  navigation_steps.html    - static help documentation
  navigation_themes.html   - static help documentation
  peve.html                - static documentation
  privacy.html             - static documentation
  teaching.html            - static documentation
  
Most of the resources in the framework directory are taken directly, or
modified from, the standard framework directory included with the processor's
'peve-stuart2007' template.


A. Plugin Development Notes

A.1 Basics

Plugins come in two flavours: input and output. Input plugins (also referred 
to as input handlers) take some arbitrary document format and produce a 
heirarchy of 'Intermediate Format Files' (IFF - not to be confused with EA
Interchange File Format files) suitable for processing by the output plugins.

Output plugins take IFF files and produce a CBT or other document package 
from them, possibly using templates or other resources to construct the output
files in addition to the IFF files.

BA2 Intermediate File Format

The intermediate format generated by input plugins and processed by output 
plugins is a HTML based format compatible with that generated by latex2html. A
minimal intermediate format file would look like

<html>
<head>
    <title>Step title</title>
</head>
<body>
Step content
</body>
</html>
