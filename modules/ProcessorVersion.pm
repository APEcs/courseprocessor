package ProcessorVersion;

use Exporter;
use strict;

our @ISA       = qw(Exporter);
our @EXPORT    = qw(get_version);

my $wiki2course = "1.19 (23 June 2011)";
my $course2wiki = "1.0 (27 June 2011)";
my $processor   = "3.8.3 (27 June 2011)";
my $release     = "3.8.3a";

sub get_version {
    my $mode = shift;

    if(lc($mode) eq "processor") {
        return "Processor $processor [Toolchain version $release]";
    } elsif(lc($mode) eq "wiki2course") {
        return "Wiki export tool $wiki2course [Toolchain version $release]";
    } elsif(lc($mode) eq "course2wiki") {
        return "Course import tool $course2wiki [Toolchain version $release]";
    } else {
        return "Unknown mode";
    }
}

1;
