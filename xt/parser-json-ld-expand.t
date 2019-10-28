use v5.18;
use autodie;
use utf8;
use Carp qw(confess);
use Test::More;
use Test::Exception;
use FindBin qw($Bin);
use File::Glob qw(bsd_glob);
use File::Spec;
use JSON qw(decode_json);
use Data::Dumper;
use JSONLD;

use Moo;
use Attean;
use Type::Tiny::Role;

our $debug	= 0;
$JSONLD::debug	= $debug;
our $PATTERN;
if ($debug) {
	$PATTERN = qr/t0028/;
} else {
	$PATTERN	= /./;
}

sub load_json {
	my $file	= shift;
	open(my $fh, '<', $file);
	my $j	= JSON->new();
	$j->boolean_values(0, 1);
	return $j->decode(do { local($/); <$fh> });
}

$Data::Dumper::Sortkeys	= 1;
my $path	= File::Spec->catfile( $Bin, 'data', 'json-ld-api-w3c' );
my $manifest	= File::Spec->catfile($path, 'expand-manifest.jsonld');
my $d		= load_json($manifest);
my $tests	= $d->{'sequence'};
my $base	= IRI->new(value => $d->{'baseIri'} // 'http://example.org/');
foreach my $t (@$tests) {
	my $id		= $t->{'@id'};
	next unless ($id =~ $PATTERN);
	
	my $input	= $t->{'input'};
	my $expect	= $t->{'expect'};
	my $name	= $t->{'name'};
	my $purpose	= $t->{'purpose'};
	my @types	= @{ $t->{'@type'} };
	my %types	= map { $_ => 1 } @types;

	my $j		= JSON->new->canonical(1)->allow_nonref(1);
	$j->boolean_values(0, 1);
	if ($types{'jld:PositiveEvaluationTest'}) {
		note($id);
		my $test_base	= IRI->new(value => $input, base => $base)->abs;
		my $jld			= JSONLD->new(base_iri => IRI->new($test_base));
		my $infile		= File::Spec->catfile($path, $input);
		my $outfile		= File::Spec->catfile($path, $expect);
		my $data		= load_json($infile);
		my $expected	= $j->encode(load_json($outfile));
		if ($debug) {
			warn "Input file: $infile\n";
			warn "INPUT:\n===============\n" . Dumper($data);
		}
		my $expanded	= eval { $jld->expand($data) };
		if ($@) {
			diag("Died: $@");
		}
		my $got			= $j->encode($expanded);
		if ($debug) {
			warn "EXPECT:\n===============\n" . Dumper($j->decode($expected));
			warn "OUTPUT:\n===============\n" . Dumper($j->decode($got));
		}
		is($got, $expected, "$id: $name");
	} elsif ($types{'jld:NegativeEvaluationTest'}){
		diag("TODO: NegativeEvaluationTest $id\n");
	} else {
		diag("Not a recognized evaluation test: " . Dumper(\@types));
		next;
	}
}

done_testing();
