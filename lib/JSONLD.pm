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

package JSONLD {
	use Moo;
	use IRI;
	use JSON;
	use List::Util qw(all any);
	use Debug::ShowStuff qw(indent println);
	use Data::Dumper;
	use Carp qw(confess);
	use Clone 'clone';
	use namespace::clean;
	
	has 'base_iri' => (is => 'rw', required => 0, default => sub { IRI->new('http://example.org/') });
	has 'processing_mode' => (is => 'ro', default => 'json-ld-1.1');

	our $debug		= 0;
	my %keywords	= map { $_ => 1 } qw(: @base @container @context @direction @graph @id @import @included @index @json @language @list @nest @none @prefix @propagate @protected @reverse @set @type @value @version @vocab);
	
	sub expand {
		my $self	= shift;
		my $d		= shift;
# 		warn "Expanding...";
		return $self->_expand(undef, undef, $d);
	}
	
	sub _expand {
		my $self	= shift;
		my $ctx		= shift // {};
		my $prop	= shift;
		my $d		= shift;
		my $v	= $self->_5_1_2_expansion($ctx, $prop, $d, @_);
		if (ref($v) eq 'HASH') {
			my @keys	= keys %$v;
			if (scalar(@keys) == 1 and $keys[0] eq '@graph') {
				$v	= $v->{'@graph'};
			}
		}
		unless (defined($v)) {
			$v	= [];
		}
		
		if (ref($v) ne 'ARRAY') {
			$v	= [$v];
		}
		
		return $v;
	}
	
	sub _is_abs_iri {
		my $self	= shift;
		my $value	= shift;
		my $i		= eval { IRI->new($value) };
		return 0 unless ($i);
		return ($value eq $i->abs);
	}
	
	sub _is_iri {
		my $self	= shift;
		my $value	= shift;
		my $i		= eval { IRI->new(value => $value) };
		my $err		= $@;
		my $is_iri	= not($@);
		if ($@) {
			Carp::confess $@;
		}
		return $is_iri;
	}

	sub _cm_contains {
		my $self	= shift;
		my $container_mapping	= shift;
		my $value	= shift;
		if (ref($container_mapping)) {
			Carp::cluck unless (ref($container_mapping) eq 'ARRAY');
			return any { $_ eq $value } @$container_mapping;
		} else {
			return (defined($container_mapping) and $container_mapping eq $value);
		}
	}
	
	sub _cm_contains_any {
		my $self	= shift;
		my $container_mapping	= shift;
		my @values	= shift;
		foreach my $value (@values) {
			return 1 if ($self->_cm_contains($container_mapping, $value));
		}
		return 0;
	}
	
	sub _ctx_term_defn {
		my $self	= shift;
		my $ctx		= shift;
		my $term	= shift;
		confess "Bad context type in _ctx_term_defn: " . ref($ctx) unless (ref($ctx) eq 'HASH');
		no warnings 'uninitialized';
		return $ctx->{terms}{$term};
	}

	sub _ctx_contains_protected_terms {
		my $self	= shift;
		my $ctx		= shift;
		foreach my $term (keys %{ $ctx->{terms} }) {
			return 1 if $term->{protected};
		}
		return 0;
	}
	
	sub _is_node_object {
		my $self	= shift;
		my $value	= shift;
		return 0 unless (ref($value) eq 'HASH');
		foreach my $p (qw(@value @list @set)) {
			return 0 if (exists $value->{$p});
		}
		# TODO: check that value "is not the top-most map in the JSON-LD document consisting of no other entries than @graph and @context."
		return 1;
	}
	
	sub _is_value_object {
		my $self	= shift;
		my $value	= shift;
		return 0 unless (ref($value) eq 'HASH');
		return (exists $value->{'@value'});
	}

	sub _is_list_object {
		my $self	= shift;
		my $value	= shift;
		return 0 unless (ref($value) eq 'HASH');
		return (exists $value->{'@list'});
	}
	
	sub _4_1_2_ctx_processing {
		println "ENTER    =================> _4_1_2_ctx_processing" if $debug;
		my $__indent	= indent();
		my $self		= shift;
		my $activeCtx	= shift;
		my $localCtx	= shift;
		local($Data::Dumper::Indent)	= 0;
		println(Data::Dumper->Dump([$activeCtx], ['*activeCtx'])) if $debug;
		println(Data::Dumper->Dump([$localCtx], ['*localCtx'])) if $debug;
		my %args		= @_;
		my $propagate	= $args{propagate} // 1;
		my $remote_contexts	= $args{remote_contexts} // [];
		my $override_protected	= $args{override_protected} // 0;
		
		println "1" if $debug;
		my $result	= clone($activeCtx); # 1
		confess "Bad active context type in _4_1_2_ctx_processing: " . Dumper($activeCtx) unless (ref($activeCtx) eq 'HASH');
		if (ref($localCtx) eq 'HASH' and exists $localCtx->{'@propagate'}) {
			println "2" if $debug;
			$propagate	= ($localCtx->{'@propagate'} eq 'true'); # 2
		}
		
		if (not($propagate) and not exists $result->{previous_context}) {
			println "3" if $debug;
			$result->{previous_context}	= $activeCtx; # 3
		}
		
		if (ref($localCtx) ne 'ARRAY') {
			println "4" if $debug;
			$localCtx = [$localCtx]; # 4
		}
		
		foreach my $context (@$localCtx) {
			# 5
			println "5" if $debug;
			if (not(defined($context))) {
				# 5.1
				println "5.1" if $debug;
				if (not($override_protected) and $self->_ctx_contains_protected_terms($activeCtx)) {
					println "5.1.1" if $debug;
					die 'invalid context nullification'; # 5.1.1
				} else {
					println "5.1.2 moving to next context" if $debug;
					my $prev	= $result;
					$result	= {};
					if ($propagate) {
						$result->{previous_context}	= $prev;
					}
					next;
				}
			}

			if (not(ref($context))) {
				println "5.2" if $debug;
				
				println "5.2.1 TODO"; # if $debug;
				println "5.2.2 TODO"; # if $debug;
				println "5.2.3 TODO"; # if $debug;
				println "5.2.4 TODO"; # if $debug;
				println "5.2.5 TODO"; # if $debug;
				println "5.2.6 TODO"; # if $debug;

				println "5.2.7 moving to next context" if $debug;
				next;
			}

			if (ref($context) ne 'HASH') {
				println "5.3" if $debug;
				die "invalid_local_context"; # 5.3
			}
			
			println "5.4" if $debug; # no-op

			if (exists $context->{'@version'}) {
				println "5.5" if $debug;
				my $v	= $context->{'@version'};
				if ($v ne '1.1') {
					println "5.5.1" if $debug;
					die 'invalid @version value'; # 5.5.1
				}
				println "5.5.2 TODO" if $debug;
			}

			if (exists $context->{'@import'}) {
				println "5.6 TODO" if $debug;
			}
			
			if (exists $context->{'@base'} and scalar(@$remote_contexts) == 0) {
				println "5.7" if $debug;
				println "5.7.1" if $debug;
				my $value	= $context->{'@base'};
				
				if (not defined($value)) {
					println "5.7.2" if $debug;
					delete $result->{'@base'};
				} elsif ($self->_is_abs_iri($value)) {
					println "5.7.3" if $debug;
					$result->{'@base'}	= $value;
				} elsif ($self->_is_iri($value) and defined($result->{'@base'})) {
					println "5.7.4" if $debug;
					my $base	= IRI->new($result->{'@base'});
					my $i	= IRI->new(value => $value, base => $base);
					$result->{'@base'}	= $i->abs;
				} else {
					println "5.7.5" if $debug;
					die 'invalid base IRI';
				}
			}
			
			if (exists $context->{'@vocab'}) {
				println "5.8" if $debug;
				println "5.8.1" if $debug;
				my $value	= $context->{'@vocab'}; # 5.8.1
				if (not defined($value)) {
					println "5.8.2" if $debug;
					delete $result->{'@vocab'}; # 5.8.2
				} elsif ($value =~ /^_/ or $self->_is_iri($value)) {
					println "5.8.3" if $debug;
					my $iri	= $self->_5_2_2_iri_expansion($result, $value, vocab => 1, documentRelative => 1);
					$result->{'@vocab'}	= $iri;
				}
			}
			
			if (exists $context->{'@language'}) {
				println "5.9 TODO" if $debug;
			}
			
			if (exists $context->{'@direction'}) {
				println "5.10 TODO" if $debug;
			}
			
			if (exists $context->{'@propagate'}) {
				println "5.11 TODO" if $debug;
			}
			
			println "5.12" if $debug;
			my $defined	= {}; # 5.12
			
			my @keys	= grep { $_ !~ /^[@](base|direction|import|language|propagate|protected|version|vocab)$/ } keys %$context;
			println "5.13" if $debug;
			foreach my $key (@keys) {
				my $__indent	= indent();
				println "5.13 [$key]" if $debug;
				my $value	= $context->{$key};
				$self->_4_2_2_create_term_definition($result, $context, $key, $defined, protected => $context->{'@protected'}, propagate => $propagate); # 5.13
			}
		}

		local($Data::Dumper::Indent)	= 1;
		println "6 returning from _4_1_2_ctx_processing with " . Data::Dumper->Dump([$result], ['final_context']) if $debug;
		return $result; # 6
	}
		
	sub _4_2_2_create_term_definition {
		my $self	= shift;
		my $activeCtx	= shift;
		my $localCtx	= shift;
		my $term		= shift;
		my $defined		= shift // {};
		println "ENTER    =================> _4_2_2_create_term_definition('$term')" if $debug;
		my $__indent	= indent();
		local($Data::Dumper::Indent)	= 0;
		println(Data::Dumper->Dump([$activeCtx], ['*activeCtx'])) if $debug;
		println(Data::Dumper->Dump([$localCtx], ['*localCtx'])) if $debug;
		println(Data::Dumper->Dump([$defined], ['*defined'])) if $debug;
		my %args		= @_;
		my $protected	= $args{protected} // 0;
		my $override_protected	= $args{override_protected} // 0;
		my $propagate	= $args{propagate} // 1;
		
		# 4.2.2
		if (exists ($defined->{$term})) {
			# 1
			println "1" if $debug;
			if ($defined->{$term}) {
				warn "returning from _4_2_2_create_term_definition: term definition has already been created\n" if $debug;
				return;
			}
			die "cyclic_IRI_mapping";
		}
		
		println "2" if $debug;
		$defined->{$term}	= 0; # 2

		println "3" if $debug;
		my $value	= clone($localCtx->{$term}); # 3
		
		# NOTE: the language interaction between 4 and 5 here is a mess. Unclear what "Otherwise" applies to. Similarly with the "Otherwise" that begins 7 below.
		if ($self->processing_mode eq 'json-ld-1.1' and $term eq '@type') {
			# 4
			println "4" if $debug;
			unless (ref($value) eq 'HASH') {
				die 'keyword redefinition';
			}
			my @keys	= grep { $_ ne '@protected' } keys %$value;
			die 'keyword redefinition' unless (scalar(@keys) == 1 and $keys[0] eq '@container');
			die 'keyword redefinition' unless ($value->{'@container'} eq '@set');
		} else {
			# 5
			println "5" if $debug;
			if (exists $keywords{$term}) {
				die 'keyword redefinition';
			}
			if (substr($term, 0, 1) eq '@') {
				# https://www.w3.org/2018/json-ld-wg/Meetings/Minutes/2019/2019-09-20-json-ld#section5-2
				warn "create term definition attempted on a term that looks like a keyword: $term\n";
				println "5 returning so as to ignore a term that has the form of a keyword: $term" if $debug;
				return;
			}
		}
		
		println "6" if $debug;
		my $previous_defn	= $self->_ctx_term_defn($activeCtx, $term); # 6
		delete $activeCtx->{terms}{$term}; # https://github.com/w3c/json-ld-api/issues/176#issuecomment-545167708

# 		unless (defined($previous_defn)) {
# 			println "7" if $debug;
# 			# 7 ; NOTE: not entirely sure about the language here: what does the "Otherwise" language mean? "Otherwise, remove any previous definition from active context."
# 			delete $activeCtx->{terms}{$term};
# 		}

		my $simple_term;
		if (not(defined($value))) {
			println "8" if $debug;
			$value	= {'@id' => undef}; # 8
		} elsif (not(ref($value))) {
			# 9
			println "9" if $debug;
			$value	= {'@id' => $value};
			$simple_term	= 1;
		} elsif (ref($value) eq 'HASH') {
			println "10" if $debug;
			$simple_term	= 0; # 10
		} else {
			println "10" if $debug;
			die "invalid_term_definition"; # 10
		}
		
		println "11" if $debug;
		my $definition	= {};	# 11
		
		if ($value->{'@protected'}) {
			println "12" if $debug;
			$definition->{protected}	= 1; # 12
			println "12 TODO processing mode of json-ld-1.0" if $debug;
		} elsif (not exists $value->{'@protected'} and $protected) {
			println "13" if $debug;
			$definition->{protected}	= 1; # 13
		}

		if (exists $value->{'@type'}) {
			# 14
			println "14" if $debug;
			my $type	= $value->{'@type'}; # 14.1
			if (ref($type)) {
				println "14.1" if $debug;
				die "invalid_type_mapping"; # 14.1
			}
			
			println "14.2" if $debug;
			$type	= $self->_5_2_2_iri_expansion($activeCtx, $type, vocab => 1, localCtx => $localCtx, 'defined' => $defined); # 14.2

			if (($type eq '@json' or $type eq '@none') and $self->processing_mode eq 'json-ld-1.0') {
				println "14.3" if $debug;
				die 'invalid type mapping';
			}

			if ($type ne '@id' and $type ne '@vocab' and not($self->_is_abs_iri($type))) {
				# TODO: handle case "nor, if processing mode is json-ld-1.1, @json nor @none"
				println "14.4" if $debug;
				die 'invalid type mapping'; # 14.4
			}
			
			println "14.5" if $debug;
			$definition->{type_mapping}	= $type; # 14.5
		}
		
		if (exists $value->{'@reverse'}) {
			# 15
			println "15" if $debug;
			if (exists $value->{'@id'} or exists $value->{'@nest'}) {
				println "15.1" if $debug;
				die 'invalid reverse property'; # 15.1
			}
			my $reverse	= $value->{'@reverse'};
			if (ref($reverse)) {
				println "15.2" if $debug;
				die 'invalid IRI mapping'; # 15.2
			}
			if (substr($reverse, 0, 1) eq '@') {
				println "15.3" if $debug;
				die '@reverse value looks like a keyword: ' . $reverse; # 15.3
			} else {
				 # 15.4
				println "15.4" if $debug;
				my $m	= $self->_5_2_2_iri_expansion($activeCtx, $reverse, vocab => 1, localCtx => $localCtx, 'defined' => $defined);
				if (not($self->_is_abs_iri($m)) and $m !~ /^:/) {
					die 'invalid IRI mapping';
				}
				$definition->{iri_mapping}	= $m;
			}
			
			if (exists $value->{'@container'}) {
				# 15.5
				println "15.5" if $debug;
				my $c	= $value->{'@container'};
				if ($c ne '@set' and $c ne '@index' and not(defined($c))) {
					die 'invalid reverse property';
				}
				$definition->{container_mapping}	= $c;
			}
			
			println "15.6" if $debug;
			$definition->{'reverse'}	= 1; # 15.6
			
			# 15.7
			println "15.7" if $debug;
			$activeCtx->{terms}{$term}	= $definition;
			$defined->{$term}	= 1;
			local($Data::Dumper::Indent)	= 0;
			println "returning from _4_2_2_create_term_definition: " . Dumper($activeCtx->{terms}{$term}) if $debug;
			return;
		}

		println "16" if $debug;
		$definition->{'reverse'}	= 0; # 15
		
		if (exists $value->{'@id'} and $value->{'@id'} ne $term) {
			# 17
			println "17" if $debug;
			my $id	= $value->{'@id'};
			if (exists $value->{'@id'} and not(defined($id))) {
				println "17.1" if $debug;
				# 17.1
			} elsif (ref($id)) {
				println "17.2" if $debug;
				die 'invalid IRI mapping'; # 17.2
			}
			
			if (not exists $keywords{$id} and substr($id, 0, 1) eq '@') {
				println "17.3" if $debug;
				die 'create term definition encountered an @id that looks like a keyword: ' . $id; # 17.3
			} else {
				# 17.4
				println "17.4" if $debug;
				my $iri	= $self->_5_2_2_iri_expansion($activeCtx, $id, vocab => 1, localCtx => $localCtx, 'defined' => $defined);
				if (not exists $keywords{$iri} and not $self->_is_abs_iri($iri) and $iri !~ /:/) {
					die 'invalid IRI mapping';
				}
				if ($iri eq '@context') {
					die 'invalid keyword alias';
				}
				$definition->{iri_mapping}	= $iri;
			}
			if ($term =~ /:./) {
				println "17.5" if $debug;
				my $iri	= $self->_5_2_2_iri_expansion($activeCtx, $term, vocab => 1, localCtx => $localCtx, 'defined' => $defined);
				if ($iri ne $definition->{iri_mapping}) {
					die 'invalid IRI mapping'; # 17.5 ; NOTE: the text here doesn't discuss what parameters to pass to IRI expansion
				}
			}
			
			if ($term !~ m{[:/]} and $simple_term and $definition->{iri_mapping} =~ m{[][:/?#@]$}) {
				println "17.6" if $debug;
				$definition->{prefix}	= 1; # 17.6
			}
		} elsif ($term =~ /:/) {
			# 18
			println "18" if $debug;
			my ($prefix, $suffix)	= split(/:/, $term, 2);
			if (exists $localCtx->{$prefix}) {
				println "18.1" if $debug;
				$self->_4_2_2_create_term_definition($activeCtx, $localCtx, $prefix, $defined); # 18.1
			}
			if (exists $activeCtx->{terms}{$prefix}) {
				println "18.2" if $debug;
				$definition->{iri_mapping}	= $activeCtx->{terms}{$prefix}{iri_mapping} . $suffix; # 18.2
			} else {
				println "18.3" if $debug;
				$definition->{iri_mapping}	= $term; # 18.3
			}
		} elsif ($term =~ m{/}) {
			# TODO: 19
			println "19 TODO"; # if $debug;
		} elsif ($term eq '@type') {
			println "20" if $debug;
			$definition->{iri_mapping}	= '@type'; # 20
		} else {
			# 21 ; NOTE: this section uses a passive voice "the IRI mapping of definition is set to ..." cf. 18 where it's active: "set the IRI mapping of definition to @type"
			println "21" if $debug;
			if (exists $activeCtx->{'@vocab'}) {
				$definition->{iri_mapping}	= $activeCtx->{'@vocab'} . $term;
			} else {
				die 'invalid IRI mapping';
			}
		}
		
		if (exists $value->{'@container'}) {
			# TODO: 22
			println "22"; # if $debug;

			println "22.1" if $debug;
			my $container	= $value->{'@container'}; # 22.1

			# 22.1 error checking
			my %acceptable	= map { $_ => 1 } qw(@graph @id @index @language @list @set @type);
			if (exists $acceptable{$container}) {
			} elsif (ref($container) eq 'ARRAY') {
				if (scalar(@$container) == 1) {
					my ($c)	= @$container;
					unless (exists $acceptable{$c}) {
						die 'invalid container mapping';
					}
				} elsif (any { $_ eq '@graph' } @$container and any { $_ =~ /^[@](id|index)$/ } @$container) {
					
				} elsif (any { $_ eq '@set' } @$container and any { $_ =~ /^[@](id|index|type|language)$/ } @$container) {
					
				} else {
					die 'invalid container mapping';
				}
			} else {
				die 'invalid container mapping';
			}
			
			if ($self->processing_mode eq 'json-ld-1.0') {
				if (any { $container eq $_ } qw (@graph @id @type) or ref($container)) {
					println "22.2" if $debug;
					die 'invalid container mapping';
				}
			}
			
			println "22.3" if $debug;
			if (ref($container) eq 'ARRAY') {
				$definition->{container_mapping}	= $container; # 22.3
			} else {
				$definition->{container_mapping}	= [$container]; # 22.3
			}
			
			if ($container eq '@type') {
				println "22.4" if $debug;
				if (not defined($definition->{type_mapping})) {
					println "22.4.1" if $debug;
					$definition->{type_mapping}	= '@id';
				}
				
				my $tm	= $definition->{type_mapping};
				if ($tm ne '@id' and $tm ne '@vocab') {
					println "22.4.2" if $debug;
					die 'invalid type mapping';
				}
			}
		}

		if (exists $value->{'@index'}) {
			# TODO: 23
			println "23 TODO" if $debug;
		}

		if (exists $value->{'@context'}) {
			# TODO: 24
			println "24 TODO" if $debug;
		}

		if (exists $value->{'@language'} and not exists $value->{'@type'}) {
			# TODO: 25
			println "25 TODO" if $debug;
		}

		if (exists $value->{'@direction'} and not exists $value->{'@type'}) {
			# TODO: 26
			println "26 TODO" if $debug;
		}

		if (exists $value->{'@nest'}) {
			# TODO: 27
			println "27 TODO" if $debug;
		}

		if (exists $value->{'@prefix'}) {
			# TODO: 28
			println "28 TODO" if $debug;
# 			if ($self->processing_mode eq 'json-ld-1.0' or $term =~ /:/) {
# 				println "28.1" if $debug;
# 				die 'invalid term definition'; # 28.1
# 			}
# 			
# 			$definition->{prefix}	= $value->{'@prefix'};
			
		}

		my @keys	= grep { not /^[@](id|reverse|container|context|language|nest|prefix|type)$/ } keys %$value;
		if (scalar(@keys)) {
			die 'invalid term definition'; # 29
		}
		
		if (not($override_protected) and $previous_defn->{protected}) {
			# 30
			println "30" if $debug;
			my %cmp_a	= map { $_ => $definition->{$_} } grep { $_ ne 'protected' } keys %$definition;
			my %cmp_b	= map { $_ => $previous_defn->{$_} } grep { $_ ne 'protected' } keys %$previous_defn;
			my $j		= JSON->new->canonical(1);
			if ($j->encode(\%cmp_a) ne $j->encode(\%cmp_b)) {
				println "30.1" if $debug;
				die 'protected term redefinition'; # 30.1
			}
			println "30.2" if $debug;
			$definition	= $previous_defn; # 30.2
		}
		
		println "31" if $debug;
		$activeCtx->{terms}{$term}	= $definition; # 31
		$defined->{$term}	= 1; # 31
		local($Data::Dumper::Indent)	= 0;
		println "returning from _4_2_2_create_term_definition: " . Dumper($activeCtx->{terms}{$term}) if $debug;
		return;
	}
	
	sub _5_1_2_expansion {
		my $self		= shift;
		my $activeCtx	= shift;
		my $activeProp	= shift;
		my $element		= shift;
		println "ENTER    =================> _5_1_2_expansion('$activeProp')" if $debug;
		my $__indent	= indent();
		local($Data::Dumper::Indent)	= 0;
		println(Data::Dumper->Dump([$activeCtx], ['activeCtx'])) if $debug;
		println(Data::Dumper->Dump([$element], ['element'])) if $debug;
		my $frameExpansion	= shift // 0;
		my $ordered		= shift // 0;
		my $fromMap		= shift // 0;
		
		unless (defined($element)) {
			println "1 returning from _5_1_2_expansion: undefined element" if $debug;
			return; # 1
		}
		if (defined($activeProp) and $activeProp eq '@default') {
			println "2" if $debug;
			$frameExpansion = 0; # 2
		}
		
		my $property_scoped_ctx;
		my $tdef = $self->_ctx_term_defn($activeCtx, $activeProp);
		if ($tdef and my $lctx = $tdef->{'@context'}) {
			println "3" if $debug;
			$property_scoped_ctx	= $lctx; # 3
		}
		
		if (not(ref($element))) {
			# 4
			println "4" if $debug;
			if (not(defined($activeProp)) or $activeProp eq '@graph') {
				println "4.1 returning from _5_1_2_expansion: free floating scalar" if $debug;
				return; # 4.1
			}
			if (defined($property_scoped_ctx)) {
				println "4.2" if $debug;
				$activeCtx = $self->_4_1_2_ctx_processing($activeCtx, $property_scoped_ctx); # 4.2
			}
			
			my $v	= $self->_5_3_2_value_expand($activeCtx, $activeProp, $element);
			local($Data::Dumper::Indent)	= 1;
			println "4.3 returning from _5_1_2_expansion with " . Data::Dumper->Dump([$v], ['expandedValue']) if $debug;
			return $v; # 4.3
		}
		
		if (ref($element) eq 'ARRAY') {
			# 5
			println "5" if $debug;
			my @result; # 5.1
			println "5.1" if $debug;
			foreach my $item (@$element) {
				# 5.2
				println "5.2" if $debug;
				println "5.2.1" if $debug;
				my $expandedItem	= $self->_5_1_2_expansion($activeCtx, $activeProp, $item); # 5.2.1
				println "5.2.1 expanded item = " . Dumper($expandedItem) if $debug;
				
				# NOTE: 5.2.2 "container mapping" is in the term definition for active property, right? The text omits the term definition reference.
				my $container_mapping	= $tdef->{container_mapping};
#				if (any { $_ eq '@list'} @$container_mapping and ref($expandedItem) eq 'ARRAY') {
				if ($self->_cm_contains($container_mapping, '@list')  and ref($expandedItem) eq 'ARRAY') {
					println "5.2.2" if $debug;
					$expandedItem	= { '@list' => $expandedItem }; # 5.2.2
				}
				
				# 5.2.3
				println "5.2.3" if $debug;
				if (ref($expandedItem) eq 'ARRAY') {
					push(@result, @$expandedItem);
				} elsif (defined($expandedItem)) {
					push(@result, $expandedItem);
				}
			}
			
			local($Data::Dumper::Indent)	= 1;
			println "5.3 returning from _5_1_2_expansion with " . Data::Dumper->Dump([\@result], ['expanded_array_value']) if $debug;
			return \@result; # 5.3
		}
		
		println "6" if $debug;
		die "Unexpected non-map encountered during expansion: $element" unless (ref($element) eq 'HASH'); # 6; assert

		if (my $prevCtx = $activeCtx->{previous_context}) {
			unless ($fromMap) {
				unless (exists $element->{'@value'}) {
					my @keys	= keys %$element;
					unless (scalar(@keys) == 1 and $keys[0] eq '@id') {
						println "7" if $debug;
						$activeCtx	= $prevCtx; # 7
					}
				}
			}
		}
		
		if (defined($property_scoped_ctx)) {
			println "8" if $debug;
			$activeCtx = $self->_4_1_2_ctx_processing($activeCtx, $property_scoped_ctx); # 8
		}
		
		if (my $c = $element->{'@context'}) {
			println "9" if $debug;
			$activeCtx = $self->_4_1_2_ctx_processing($activeCtx, $c); # 9
		}
		
		println "10" if $debug;
		my $type_scoped_ctx	= $activeCtx; # 10
		
		println "11" if $debug;
		foreach my $key (sort keys %$element) {
			my $__indent	= indent();
			my $value	= $element->{$key};
			# 11
			println "11 [$key]" if $debug;
			unless ('@type' eq $self->_5_2_2_iri_expansion($activeCtx, $key, vocab => 1)) {
				println "[skipping key $key in search of \@type]" if $debug;
				next;
			}

			println "11 body [$key]" if $debug;
			
			unless (ref($value) eq 'ARRAY') {
				println "11.1" if $debug;
				$value	= [$value]; # 11.1
			}
			
			foreach my $term (sort @$value) {
				println "11.2 attempting with [$term]" if $debug;
				if (not(ref($term))) {
					my $tdef	= $self->_ctx_term_defn($activeCtx, $term);
					if (my $c = $tdef->{'@context'}) {
						println "11.2" if $debug;
						$activeCtx	= $self->_4_1_2_ctx_processing($activeCtx, $c, propagate => 1); # 11.2
					}
				}
			}
			
		}
		println "After 11, " . Data::Dumper->Dump([$element], ['element']) if $debug;
		
		println "12" if $debug;
		my $result	= {}; # 12a
		my $nests	= {}; # 12b
		my $input_type	= '';
		foreach my $key (sort keys %$element) {
			if ($key eq '@type') {
				$input_type	= $element->{$key};
				last;
			}
		}
		
		my @elements	= ($element);
		while (my $element = shift(@elements)) {
			println "13 --- processing element" if ($debug);
			foreach my $key (sort keys %$element) {
				my $__indent	= indent();
				my $value	= $element->{$key};
				# 13
				println '-----------------------------------------------------------------' if $debug;
				println "13 [$key] " . Data::Dumper->Dump([$value], ['value']) if $debug;
				if ($key eq '@context') {
					println "13.1 going to next element key" if $debug;
					next; # 13.1
				}
				println "13.2" if $debug;
				my $expandedProperty	= $self->_5_2_2_iri_expansion($activeCtx, $key, vocab => 1); # 13.2
				if (not(defined($expandedProperty)) or ($expandedProperty !~ /:/ and not exists $keywords{$expandedProperty})) {
					println "13.3 going to next element key" if $debug;
					next; # 13.3
				}
			
				my $expandedValue;
				if (exists $keywords{$expandedProperty}) {
					# 13.4
					println "13.4 keyword: $expandedProperty" if $debug;
					
					# TODO: 13.4.1
					if (defined($activeProp) and $activeProp eq '@reverse') {
						println "13.4.1" if $debug;
						die 'invalid reverse property map'; # 13.4.1
					}

					if (exists $result->{$expandedProperty}) {
						my $p	= $result->{$expandedProperty};
						if ($p ne '@included' and $p ne '@type') {
							println "13.4.2" if $debug;
							die 'colliding keywords'; # 13.4.2
						}
					}
					
					# NOTE: another case of an "Otherwise" applying to a partial conjunction
					if ($expandedProperty eq '@id') {
						if (ref($value)) {
							println "13.4.4 invalid" if $debug;
							die 'invalid @id value';
						} else {
							println "13.4.4" if $debug;
							$expandedValue	= $self->_5_2_2_iri_expansion($activeCtx, $value, documentRelative => 1);
							println "13.4.4 resulting in " . Data::Dumper->Dump([$expandedValue], ['*expandedValue']) if $debug;
						}
					}

					if ($expandedProperty eq '@type') {
						my $is_string = not(ref($value));
						my $is_array	= ref($value) eq 'ARRAY';
						my $is_array_of_strings	= ($is_array and all { not(ref($_)) } @$value);
						if (not($is_string) and not($is_array_of_strings)) {
							println "13.4.5 invalid" if $debug;
							die 'invalid type value';
						} else {
							# 13.4.5
							println "13.4.5" if $debug;
							if ($is_string) {
								$expandedValue	= $self->_5_2_2_iri_expansion($type_scoped_ctx, $value, vocab => 1, documentRelative => 1);
							} else {
								my @values	= @$value;
								$expandedValue	= [map {
									$self->_5_2_2_iri_expansion($type_scoped_ctx, $_, vocab => 1, documentRelative => 1)
								} @values];
							}
							if (exists $result->{'@type'}) {
								my $already	= $result->{'@type'};
								my @types	= (ref($already) eq 'ARRAY') ? @$already : ($already);
								unshift(@$expandedValue, @types);
							}
						}
					}

					if ($expandedProperty eq '@graph') {
						println "13.4.6" if $debug;
						my $v	= $self->_expand($activeCtx, '@graph', $value, frameExpansion => $frameExpansion, ordered => $ordered); # 13.4.6
						# TODO: ensure that expanded value is an array of one or more maps
						$expandedValue	= $v;
					}

					if ($expandedProperty eq '@included') {
						println "13.4.7" if $debug;
						if ($self->processing_mode eq 'json-ld-1.1') {
							println "13.4.7.1" if $debug;
							next;
						}
						
						println "13.4.7.2" if $debug;
						$expandedValue	= $self->_expand($activeCtx, $activeProp, $value, frameExpansion => $frameExpansion, ordered => $ordered); # 13.4.6
						unless (ref($expandedValue) eq 'ARRAY') {
							$expandedValue	= [$expandedValue];
						}
						
						foreach my $v (@$expandedValue) {
							unless ($self->_is_node_object($v)) {
								println "13.4.7.3" if $debug;
								die 'invalid @included value';
							}
						}
						
						if (exists $result->{'@include'}) {
							println "13.4.7.4" if $debug;
							unshift(@$expandedValue, $result->{'@include'});
						}
					} elsif ($expandedProperty eq '@value') {
						println "13.4.8" if $debug;
						if ($input_type eq '@json') {
							println "13.4.8.1" if $debug;
							$expandedValue	= $value; # 13.4.8.1
							if ($self->processing_mode eq 'json-ld-1.0') {
								die 'invalid value object value';
							}
						} elsif (ref($value) and defined($value)) {
							println "13.4.8.2" if $debug; # NOTE: the language here is ambiguous: "if value is not a scalar or null"
							die 'invalid value object value';
						} else {
							println "13.4.8.3" if $debug;
							$expandedValue	= $value;
						}
						
						unless (defined($expandedValue)) {
							println "13.4.8.4" if $debug;
							$result->{'@value'}	= undef;
							next;
						}
						
						if ($frameExpansion) {
							println "13.4.8.5 TODO: frameExpansion support"; # if $debug;
						}
					}

					# NOTE: again with the "Otherwise" that seems to apply to only half the conjunction
					if ($expandedProperty eq '@language') {
						println "13.4.9" if $debug;
						if (ref($value)) {
							die 'invalid language-tagged string';
						}
						$expandedValue	= $value; # 13.4.9
						if ($frameExpansion) {
							println "13.4.9 TODO: frameExpansion support"; # if $debug;
						}
					}

					if ($expandedProperty eq '@direction') {
						println "13.4.10" if $debug;
						if ($self->processing_mode eq 'json-ld-1.0') {
							println "13.4.10.1" if $debug;
							next;
						}

						if ($value ne 'ltr' and $value ne 'rtl') {
							println "13.4.10.2" if $debug;
							die 'invalid base direction';
						}

						println "13.4.10.3" if $debug;
						$expandedValue	= $value;

						if ($frameExpansion) {
							println "13.4.10.4 TODO: frameExpansion support"; # if $debug;
						}
					}

					if ($expandedProperty eq '@index') {
						println "13.4.11" if $debug;
						if (ref($value)) {
							println "13.4.11.1" if $debug;
							die 'invalid @index value';
						}
						
						println "13.4.11.2" if $debug;
						$expandedValue	= $value;
					}

					if ($expandedProperty eq '@list') {
						println "13.4.12" if $debug;
						if (not defined($activeProp) or $activeProp eq '@graph') {
							println "13.4.12.1" if $debug;
							next;
						}

						println "13.4.12.2" if $debug;
						$expandedValue	= $self->_5_1_2_expansion($activeCtx, $activeProp, $value, frameExpansion => $frameExpansion, ordered => $ordered);
					}

					if ($expandedProperty eq '@set') {
						println "13.4.13" if $debug;
						$expandedValue	= $self->_5_1_2_expansion($activeCtx, $activeProp, $value, frameExpansion => $frameExpansion, ordered => $ordered);
					}

					# NOTE: the language here is really confusing. the first conditional in 13.4.14 is the conjunction "expanded property is @reverse and value is not a map".
					#       however, by context it seems that really everything under 13.4.14 assumes expanded property is @reverse, and the first branch is dependent only on 'value is not a map'.
					if ($expandedProperty eq '@reverse') {
						println "13.4.14" if $debug;
						if (ref($value) ne 'HASH') {
							println "13.4.14.1" if $debug;
							die 'invalid @reverse value';
						} else {
							println "13.4.14.2" if $debug;
							$expandedValue	= $self->_expand($activeCtx, '@reverse', $value, frameExpansion => $frameExpansion, ordered => $ordered); # 13.4.14.1
							
							if (ref($expandedValue) eq 'HASH' and exists $expandedValue->{'@reverse'}) { # NOTE: spec text does not assert that expandedValue is a map
								println "13.4.14.3" if $debug;
								foreach my $property (keys %{ $expandedValue->{'@reverse'} }) {
									my $__indent	= indent();
									println "13.4.14.3 [$property]" if $debug;
									my $item	= $expandedValue->{'@reverse'}{$property};
									if (not exists $result->{$property}) {
										println "13.4.14.3.1" if $debug;
										$result->{$property}	= [];
									}
									
									println "13.4.14.3.2" if $debug;
									push(@{ $result->{$property} }, $item);
								}
							}
							
							if (ref($expandedValue) eq 'HASH') { # NOTE: spec text does not assert that expandedValue is a map
								my @keys	= grep { $_ ne '@reverse' } keys %$expandedValue;
								if (scalar(@keys)) {
									println "13.4.14.4" if $debug;
								
									if (not exists $result->{'@reverse'}) {
										println "13.4.14.4.1" if $debug;
										$result->{'@reverse'}	= {};
									}
								
									println "13.4.14.4.2" if $debug;
									my $reverse_map	= $result->{'@reverse'};
								
									println "13.4.14.4.3" if $debug;
									foreach my $property (grep { $_ ne '@reverse' } keys %{ $expandedValue }) {
										my $__indent	= indent();
										println "13.4.14.4.3 [$property]" if $debug;
										my $items	= $expandedValue->{$property};
									
										println "13.4.14.4.3.1" if $debug;
										foreach my $item (@$items) {
											my $__indent	= indent();
											if ($self->_is_value_object($item) or $self->_is_list_object($item)) {
												println "13.4.14.4.3.1.1" if $debug;
												die 'invalid reverse property value';
											}
										
											if (not exists $reverse_map->{$property}) {
												println "13.4.14.4.3.1.2" if $debug;
												$reverse_map->{$property}	= [];
											}
										
											println "13.4.14.4.3.1.3" if $debug;
											push(@{ $reverse_map->{$property} }, $item);
										}
									}
								}
							}
							
							println "13.4.14.5 going to next element key" if $debug;
							next; # 13.4.14.5
						}
					}

					if ($expandedProperty eq '@nest') {
						println "13.4.15" if $debug;
						$nests->{$key}	//= [];
						next;
					}

					if ($frameExpansion) {
						my %other_framings	= map { $_ => 1 } qw(@explicit @default @embed @explicit @omitDefault @requireAll);
						if ($other_framings{$expandedProperty}) {
							println "13.4.16" if $debug;
							$expandedValue	= $self->_expand($activeCtx, $activeProp, $value, frameExpansion => $frameExpansion, ordered => $ordered); # 13.4.16
						}
					}
					
					unless (not(defined($expandedValue)) and $expandedProperty eq '@value' and $input_type eq '@json') {
						println "13.4.17 setting " . Data::Dumper->Dump([$expandedValue], ['*expandedProperty']) if $debug;
# 						println "$expandedProperty expanded value is " . Dumper($expandedValue) if $debug;
						$result->{$expandedProperty}	= $expandedValue; # 13.4.17
					}

					println "13.4.18 going to next element key" if $debug;
					next; # 13.4.18
				}

				my $tdef	= $self->_ctx_term_defn($activeCtx, $key);
				println "13.5" if $debug;
				my $container_mapping	= $tdef->{container_mapping}; # 13.5
				if (exists($tdef->{type_mapping}) and $tdef->{type_mapping} eq '@json') {
					println "13.6" if $debug;
					$expandedValue	= { '@value' => $value, '@type' => '@json' }; # 13.6
				}
			
# 				if (exists $container_mapping->{'@language'} and ref($value) eq 'HASH') {
				if ($self->_cm_contains($container_mapping, '@language') and ref($value) eq 'HASH') {
					# TODO: 13.7
					println "13.7 TODO" if $debug;
# 				} elsif ((exists $container_mapping->{'@index'} or exists $container_mapping->{'@type'} or exists $container_mapping->{'@id'}) and ref($value) eq 'HASH') {
				} elsif ($self->_cm_contains_any($container_mapping, '@index', '@type', '@id') and ref($value) eq 'HASH') {
					# TODO: 13.8
					println "13.8 TODO" if $debug;
				} else {
					println "13.9" if $debug;
					$expandedValue	= $self->_expand($activeCtx, $key, $value, frameExpansion => $frameExpansion, ordered => $ordered); # 13.9
				}
			
				if (not(defined($expandedValue))) {
					println "13.10 going to next element key" if $debug;
					next; # 13.10
				}
			
				if ($self->_cm_contains($container_mapping, '@list') and not $self->_is_list_object($expandedValue)) {
					# 13.11
					println "13.11" if $debug;
					my @values	= (ref($expandedValue) eq 'ARRAY') ? @$expandedValue : ($expandedValue);
					$expandedValue	= { '@list' => \@values };
				}

# 				if (exists $container_mapping->{'@graph'}) {
				if ($self->_cm_contains($container_mapping, '@graph')) {
					# 13.12
					println "13.12" if $debug;
					if (ref($expandedValue) ne 'ARRAY') {
						$expandedValue	= [$expandedValue];
					}
					my @values;
					foreach my $ev (@$expandedValue) {
						if (ref($ev) eq 'HASH' and exists $ev->{'@graph'}) {
							push(@values, $ev);
						} else {
							# 13.12.1
							println "13.12.1" if $debug;
							my $av	= (ref($ev) eq 'ARRAY') ? $ev : [$ev];
							push(@values, {'@graph' => $av});
						}
					}
					$expandedValue	= \@values;
				}
			
				if ($tdef->{'reverse'}) {
					# 13.13
					println "13.13 TODO"; # if $debug;
					# TODO: 13.13.1
					# TODO: 13.13.2
					# TODO: 13.13.3
					# TODO: 13.13.4
				} else {
					# 13.14
					println "13.14" if $debug;
					println "13.14.1" if $debug;
					$result->{$expandedProperty}	//= []; # 13.14.1

					println "13.14.2" if $debug;
					if (ref($expandedValue) eq 'ARRAY') {
						push(@{$result->{$expandedProperty}}, @$expandedValue); # 13.14.2
					} elsif (ref($expandedValue)) {
						# NOTE: I'm assuming that this is the intention of 13.14.2,
						# but it isn't actually spelled out in the spec text.
						push(@{$result->{$expandedProperty}}, $expandedValue); # 13.14.2
					}
				}
			
				foreach my $nesting_key (keys %$nests) {
					# 13.15
					println "13.15" if $debug;
					println "13.15.1" if $debug;
					my $nested_values	= $nests->{$nesting_key} // []; # 13.15.1
					die "must be an array: $nested_values" unless (ref($nested_values) eq 'ARRAY');
					foreach my $nested_value (@$nested_values) {
						# 13.15.2
						println "13.15.2" if $debug;
						die 'invalid @nest value' if (ref($nested_value) ne 'HASH'); # 13.15.2.1
						# TODO: 13.15.2.1 "[If] any key within nested value expands to @value, an invalid @nest value error has been detected and processing is aborted"
						println "13.15.2.1" if $debug;
						
						println "13.15.2.2" if $debug;
						push(@elements, $nested_value); # 13.15.2.2
					}
				}
			}
		}

		if (exists $result->{'@value'}) {
			# 14
			println "14" if $debug;
			my @keys	= keys %$result;
			my %acceptable	= map { $_ => 1 } qw(@direction @index @language @type @value);
			foreach my $k (@keys) {
				println "14.1 [$k]" if $debug;
				die 'invalid value object' unless $acceptable{$k}; # 14.1
			}
			if (exists $result->{'@language'} or exists $result->{'@direction'}) {
				println "14.1 \@language handling" if $debug;
				die 'invalid value object' if (exists $result->{'@type'}); # 14.1
			}
			
			if (not(defined($result->{'@value'}))) {
				println "14.2" if $debug;
				$result	= undef; # 14.2
			} elsif (defined($result->{'@type'}) and $result->{'@type'} eq '@json') {
				# 14.3
				println "14.3" if $debug;
				# TODO: treat $result->{'@value'} as a JSON literal
			} elsif (ref($result->{'@value'}) and exists $result->{'@language'}) {
				println "14.4" if $debug;
				die 'invalid language-tagged value; ' . Dumper($result); # 14.4
			} elsif (exists $result->{'@type'} and not($self->_is_iri($result->{'@type'}))) {
				warn "Not an IRI \@type: " . Dumper($result->{'@type'});
				println "14.5" if $debug;
				die 'invalid typed value: ' . Dumper($result); # 14.5
# 			} elsif (exists $result->{'@type'}) {
# 				my $types	= $result->{'@type'};
# 				my @types	= (ref($types) eq 'ARRAY') ? @$types : $types;
# 				foreach my $t (@types) {
# 					unless ($self->_is_iri($t)) {
# 						warn "Not an IRI \@type: " . Dumper($result->{'@type'});
# 						println "14.5" if $debug;
# 						die 'invalid typed value: ' . Dumper($result); # 14.5
# 					}
# 				}
			}
		} elsif (exists $result->{'@type'} and ref($result->{'@type'}) ne 'ARRAY') {
			println "15" if $debug;
			$result->{'@type'}	= [$result->{'@type'}]; # 15
		} elsif (exists $result->{'@set'} or exists $result->{'@list'}) {
			# 16
			println "16" if $debug;
			my @keys	= grep { $_ ne '@set' and $_ ne '@list' } keys %$result;
			if (scalar(@keys)) {
				println "16.1" if $debug;
				die 'invalid set or list object' unless (scalar(@keys) == 1 and $keys[0] eq '@index'); # 16.1
			}
			if (exists $result->{'@set'}) {
				println "16.2" if $debug;
				$result	= $result->{'@set'}; # 16.2
			}
		}
		
		if (ref($result) eq 'HASH') { # NOTE: assuming based on the effects of 16.2 that this condition is necessary to guard against cases where $result is not a hashref.
			my @keys	= keys %$result;
			if (scalar(@keys) == 1 and $keys[0] eq '@language') {
				println "17" if $debug;
				$result	= undef; # 17
			}
			if (not(defined($activeProp)) or $activeProp eq '@graph') {
				# 18
				local($Data::Dumper::Indent)	= 0;
				println "18 " . Data::Dumper->Dump([$result], ['*result']) if $debug;
				if (scalar(@keys) == 0 or exists $result->{'@value'} or exists $result->{'@list'}) {
					println "18.1" if $debug;
					$result	= undef; # 18.1
				} elsif (scalar(@keys) == 1 and $keys[0] eq '@id') {
				
					unless ($frameExpansion) {
						println "18.2" if $debug;
						$result	= undef; # 18.2
					}
				}
			}
		}
		
		local($Data::Dumper::Indent)	= 1;
		println "19 returning from _5_1_2_expansion with final value " . Data::Dumper->Dump([$result], ['*result']) if $debug;
		return $result; # 19
	}
	
	sub _5_2_2_iri_expansion {
		my $self		= shift;
		my $activeCtx	= shift;
		my $value		= shift;
		println "ENTER    =================> _5_2_2_iri_expansion($value)" if $debug;
		my $__indent	= indent();
		my %args		= @_;
		my %acceptable	= map { $_ => 1 } qw(documentRelative vocab localCtx defined);
		foreach my $k (keys %args) {
			die "Not a recognized IRI expansion algorithm argument: $k" unless exists $acceptable{$k};
		}
		my $vocab				= $args{vocab} // 0;
		my $documentRelative	= $args{documentRelative} // 0;
		my $localCtx			= $args{localCtx} // {};
		my $defined				= $args{'defined'} // {};
		
		# 5.2.2 algorithm
		
		unless (defined($value) and not exists $keywords{$value}) {
			println "1 returning from _5_2_2_iri_expansion: undefined/keyword value" if $debug;
			return $value;
		}
		
		if (substr($value, 0, 1) eq '@') {
			println "2" if $debug;
			warn "IRI expansion attempted on a term that looks like a keyword: $value\n"; # 2
		}
		
		if (defined($localCtx) and my $v = $localCtx->{$value}) {
			unless ($defined->{$v}) {
				println "3" if $debug;
				$self->_4_2_2_create_term_definition($activeCtx, $localCtx, $value, $defined); # 3
			}
		}

		if (my $tdef = $self->_ctx_term_defn($activeCtx, $value)) {
			my $i	= $tdef->{iri_mapping};
			if ($keywords{$i}) {
				println "4 returning from _5_2_2_iri_expansion with a keyword" if $debug;
				return $i; # 4
			}
		}
		
		if ($vocab and my $tdef = $self->_ctx_term_defn($activeCtx, $value)) {
			my $i	= $tdef->{iri_mapping};
			println "5 returning from _5_2_2_iri_expansion with iri mapping from active context: $i" if $debug;
			return $i; # 5
		}
		
		if ($value =~ /:/) {
			 # 6
			println "6" if $debug;
			println "6.1" if $debug;
			my ($prefix, $suffix)	= split(/:/, $value, 2); # 6.1
			
			if ($prefix eq '_' or $suffix =~ m{^//}) {
				println "6.2 returning from _5_2_2_iri_expansion: already an absolute IRI or blank node identifier: $value" if $debug;
				return $value; # 6.2
			}
			
			if ($localCtx and exists $localCtx->{$prefix} and not($defined->{$prefix})) {
				println "6.3" if $debug;
				$self->_4_2_2_create_term_definition($activeCtx, $localCtx, $prefix, $defined);
			}
			
			my $tdef	= $self->_ctx_term_defn($activeCtx, $prefix);
			if ($tdef and $tdef->{iri_mapping} and $tdef->{prefix}) {
				my $i	= $tdef->{iri_mapping} . $suffix;
				println "6.4 returning from _5_2_2_iri_expansion with concatenated iri mapping and suffix: $i" if $debug;
				return $i;
			}
			
			if ($self->_is_abs_iri($value)) {
				println "6.5 returning from _5_2_2_iri_expansion with absolute IRI: $value" if $debug;
				return $value;
			}
		}
		
		if ($vocab and exists $activeCtx->{'@vocab'}) {
			my $i	= $activeCtx->{'@vocab'} . $value;
			println "7 returning from _5_2_2_iri_expansion with concatenated vocabulary mapping and value: $i" if $debug;
			return $i;
		} elsif ($documentRelative) {
			# 8
			println "8" if $debug;
			my $base = $activeCtx->{'@base'} // $self->base_iri;
			my $i = IRI->new(value => $value, base => $base);
			$value	= $i->abs;
		}

		println "9 returning from _5_2_2_iri_expansion with final value: $value" if $debug;
		return $value; # 9
	}
	
	sub _5_3_2_value_expand {
		println "ENTER    =================> _5_3_2_value_expand" if $debug;
		my $__indent	= indent();
		my $self		= shift;
		my $activeCtx	= shift;
		my $activeProp	= shift;
		my $value		= shift;
		
		my $tdef	= $self->_ctx_term_defn($activeCtx, $activeProp);

		if (exists $tdef->{type_mapping}) {
			if ($tdef->{type_mapping} eq '@id' and not(ref($value))) {
				my $iri	= $self->_5_2_2_iri_expansion($activeCtx, $value, documentRelative => 1);
				println "1 returning from _5_3_2_value_expand with new map containing \@id: $iri" if $debug;
				return { '@id' => $iri }; # 1
			}

			if ($tdef->{type_mapping} eq '@vocab' and not(ref($value))) {
				my $iri	= $self->_5_2_2_iri_expansion($activeCtx, $value, vocab => 1, documentRelative => 1);
				println "1 returning from _5_3_2_value_expand with new map containing vocab \@id: $iri" if $debug;
				return { '@id' => $iri }; # 2
			}
		}
		
		println "3" if $debug;
		my $result	= { '@value' => $value }; # 3
		
		my $tm	= $tdef->{type_mapping};
		if (exists($tdef->{type_mapping}) and $tm ne '@id' and $tm ne '@vocab' and $tm ne '@none') {
			println "4" if $debug;
			$result->{'@type'}	= $tm; # 4
		} elsif (not(ref($value))) {
			println "5" if $debug;
			println "5.1" if $debug;
			my $language	= $tdef->{language_mapping} // $activeCtx->{default_language}; # 5.1

			println "5.2" if $debug;
			my $direction	= $tdef->{direction_mapping} // $activeCtx->{default_base_direction}; # 5.2
			
			if (defined($language)) {
				println "5.3" if $debug;
				$result->{'@language'}	= $language; # 5.3
			}
			
			if (defined($direction)) {
				println "5.4" if $debug;
				$result->{'@direction'}	= $direction; # 5.4
			}
		}
		
		println "6 returning from _5_3_2_value_expand with final result" if $debug;
		return $result; # 6
	}
}
