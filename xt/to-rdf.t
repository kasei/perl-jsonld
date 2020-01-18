use v5.14;
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
use open ':std', ':encoding(UTF-8)';

use Moo;
use Attean;
use Type::Tiny::Role;

our $debug	= 0;
$JSONLD::debug	= $debug;
our $PATTERN;
if ($debug) {
	$PATTERN = qr/te030/;
# 	$PATTERN = qr/gtw/;
} else {
	$PATTERN	= qr/./;
}

package MyJSONLD {
	use v5.18;
	use autodie;
	use Moo;
	use Attean::RDF;
	extends 'JSONLD';
	
	sub default_graph {
		return iri('http://attean.example.org/default-graph');
	}

	sub add_quad {
		my $self	= shift;
		my $quad	= shift;
		my $ds		= shift;
		$ds->add_quad($quad);
	}

	sub new_dataset {
		my $self	= shift;
		my $store	= Attean->get_store('Memory')->new();
		return $store;
	}
	
	sub new_triple {
		my $self	= shift;
		foreach my $v (@_) {
			Carp::confess "not a term object" unless (ref($v));
		}
		return triple(@_);
	}
	
	sub new_quad {
		my $self	= shift;
		foreach my $v (@_) {
			unless (ref($v) and $v->does('Attean::API::Term')) {
# 				warn "not a term object: $v";
				return;
			}
		}
		return quad(@_);
	}
	
	sub skolem_prefix {
		my $self	= shift;
		return 'tag:gwilliams@cpan.org,2019-12:JSONLD:skolem:';
	}
	sub new_graphname {
		my $self	= shift;
		my $value	= shift;
		if ($value =~ /^_:(.+)$/) {
			$value	= $self->skolem_prefix() . $1;
		}
		return $self->new_iri($value);
	}

	sub new_iri {
		my $self	= shift;
		return iri(shift);
	}
	
	sub new_blank {
		my $self	= shift;
		return blank(@_);
	}
	
	sub new_lang_literal {
		my $self	= shift;
		my $value	= shift;
		my $lang	= shift;
		return langliteral($value, $lang);
	}
	
	sub canonical_json {
		my $class	= shift;
		my $value	= shift;
		my $j		= JSON->new->canonical(1);
		my $v		= $j->decode($value);
		return $j->encode($v);
	}

	sub new_dt_literal {
		my $self	= shift;
		my $value	= shift;
		my $dt		= shift;
		if ($dt eq 'http://www.w3.org/1999/02/22-rdf-syntax-ns#JSON') {
			$value	= $self->canonical_json($value);
		}
		return dtliteral($value, $dt);
	}
}

sub load_nq {
	my $file	= shift;
	open(my $fh, '<', $file);
	my $parser	= Attean->get_parser('nquads')->new();
	my $iter	= $parser->parse_iter_from_io($fh);
	my $miter	= $iter->materialize;
# 	foreach my $st ($miter->elements) {
# 		say $st->as_string;
# 	}
	return $miter->map(sub {
		# canonicalize rdf:JSON literals
		my $st	= shift;
		my $o	= $st->object;
		if ($o->does('Attean::API::Literal')) {
			my $dt	= $o->datatype;
			if ($dt and $dt->value eq 'http://www.w3.org/1999/02/22-rdf-syntax-ns#JSON') {
				my $value	= MyJSONLD->canonical_json($o->value);
				my $stclass	= ref($st);
				my @nodes	= $st->values;
				$nodes[2]	= MyJSONLD->new_dt_literal($value, 'http://www.w3.org/1999/02/22-rdf-syntax-ns#JSON');
				$st			= $stclass->new(@nodes);
			}
		}
		return $st;
	})->materialize;
}

sub load_json {
	my $file	= shift;
	open(my $fh, '<:utf8', $file);
	my $j	= JSON->new();
	return $j->utf8(0)->decode(do { local($/); <$fh> });
}

my $path	= File::Spec->catfile( $Bin, 'data', 'json-ld-api-w3c' );
my $manifest	= File::Spec->catfile($path, 'toRdf-manifest.jsonld');
my $d		= load_json($manifest);
my $tests	= $d->{'sequence'};
my $base	= IRI->new(value => $d->{'baseIri'} // 'http://example.org/');
foreach my $t (@$tests) {
	my $id		= $t->{'@id'};
	next unless ($id =~ $PATTERN);

	my $input	= $t->{'input'};
	my $expect	= $t->{'expect'} // '';
	my $name	= $t->{'name'};
	my $purpose	= $t->{'purpose'};
	my $options	= $t->{'option'} // {};
	my $_base	= $options->{'base'};
	my $spec_v	= $options->{'specVersion'} // '';
	my $genRDF	= $options->{'produceGeneralizedRdf'} // 0;
	my @types	= @{ $t->{'@type'} };
	my %types	= map { $_ => 1 } @types;
	my %args;
	if (my $rdfDir = $options->{'rdfDirection'}) {
		$args{rdf_direction}	= $rdfDir;
	}
	
	my $test_base;
	if (defined($_base)) {
		$test_base	= IRI->new(value => $_base, base => $base)->abs;
	} else {
		$test_base	= IRI->new(value => $input, base => $base)->abs;
	}
	my $j		= JSON->new->canonical(1);
	if ($spec_v eq 'json-ld-1.0') {
		diag("IGNORING JSON-LD-1.0-only test $id\n");
	} elsif ($genRDF) {
		diag("IGNORING test producing Generalized RDF: $id\n");
	} elsif ($types{'jld:PositiveEvaluationTest'} or $types{'jld:PositiveSyntaxTest'}) {
		note($id) if $debug;
		my $evalTest	= $types{'jld:PositiveEvaluationTest'};
		my $jld			= MyJSONLD->new(base_iri => IRI->new($test_base), %args);
		my $infile		= File::Spec->catfile($path, $input);
		my $data		= load_json($infile);
		my $outfile		= File::Spec->catfile($path, $expect);

		if ($debug) {
			warn "Input file: $infile\n";
			if ($evalTest) {
				warn "Output file: $outfile\n";
			}
			warn "INPUT:\n===============\n" . JSON->new->pretty->encode($data);
		}
		my $default_graph	= $jld->default_graph();
		my $got		= eval {
			my $qiter	= $jld->to_rdf($data)->get_quads()->materialize();
			my $iter	= Attean::CodeIterator->new(generator => sub {
				my $q	= $qiter->next;
				return unless ($q);
				my $g		= $q->graph;
				my $prefix	= $jld->skolem_prefix();
				if ($g->equals($default_graph)) {
					return $q->as_triple;
				} elsif (substr($g->value, 0, length($prefix)) eq $prefix) {
					my $gb		= $jld->new_blank(substr($g->value, length($prefix)));
					my @terms	= $q->values;
					$terms[3]	= $gb;
					return $jld->new_quad(@terms);
				} else {
					return $q;
				}
			}, item_type => 'Attean::API::TripleOrQuad')->materialize;
		};
		if ($@) {
			diag("Died: $@");
		}

		if ($evalTest) {
			eval {
				my $eqtest		= Attean::BindingEqualityTest->new();
				my $expected	= load_nq($outfile);
				my $ok			= ok($eqtest->equals($got, $expected), "$id: $name");
				if ($debug) {
					my @data	= (
						['EXPECTED', $expected],
						['OUTPUT__', $got],
					);
					my @files;
					my $ser	= Attean->get_serializer('nquads')->new();
					foreach my $d (@data) {
						my ($name, $data)	= @$d;
						$data->reset;
						warn "=======================\n";
						my $filename	= "/tmp/json-ld-$$-$name.out";
						open(my $fh, '>', $filename) or die $!;
						push(@files, $filename);
						print {$fh} "# $name\n";
						$ser->serialize_iter_to_io($fh, $data);
						close($fh);
					}
					unless ($ok) {
						system('/usr/local/bin/bbdiff', '--wait', '--resume', @files);
					}
				}

			};
			if ($@) {
				fail("$id: $@");
				next;
			}
		} else {
			pass("$id: PositiveSyntaxTest");
		}
	} elsif ($types{'jld:NegativeEvaluationTest'}){
		diag("IGNORING NegativeEvaluationTest $id\n");
	} else {
		diag("Not a recognized evaluation test: " . Dumper(\@types));
		next;
	}
}

done_testing();
