package ProcessorVersion;

use Exporter;
use strict;

our @ISA       = qw(Exporter);
our @EXPORT    = qw(get_version);

my $wiki2course = "1.16 (7 January 2011)";
my $processor   = "3.7.1 (28 February 2011)";
my $release     = "3.7.3";

sub get_version {
    my $mode = shift;

    if(lc($mode) eq "processor") {
        return "Processor $processor [Toolchain version $release]";
    } elsif(lc($mode) eq "wiki2course") {
        return "Wiki export tool $processor [Toolchain version $release]";
    } else {
        return "Unknown mode";
    }
}

1;
