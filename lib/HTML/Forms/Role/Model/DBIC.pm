package HTML::Forms::Role::Model::DBIC;

use HTML::Forms::Constants qw( EXCEPTION_CLASS FALSE NUL TRUE );
use HTML::Forms::Types     qw( ArrayRef HashRef Str );
use Ref::Util              qw( is_arrayref );
use Scalar::Util           qw( blessed );
use Type::Utils            qw( class_type );
use Unexpected::Functions  qw( throw );
use DBIx::Class::ResultClass::HashRefInflator;
use DBIx::Class::ResultSet::RecursiveUpdate;
use Moo::Role;
use MooX::HandlesVia;

has 'schema' => is => 'rw', isa => class_type('DBIx::Class::Schema');

has 'source_name' => is => 'lazy', isa => Str, builder => 'build_source_name';

has 'unique_constraints' =>
   is      => 'lazy',
   isa     => ArrayRef[Str],
   builder => sub {
      my $self   = shift;
      my $source = $self->resultset->result_source;

      return [ grep { $_ ne 'primary' } $source->unique_constraint_names ];
   };

has 'unique_messages' => is => 'ro', isa => HashRef, default => sub { {} };

has 'rec_update_flags' =>
   is          => 'ro',
   isa         => HashRef,
   builder     => '_build_rec_update_flags',
   handles_via => 'Hash',
   handles     => {
      set_rec_update_flag => 'set',
   };

sub build_item {
   my $self    = shift;
   my $item_id = $self->item_id or return;
   my $rs      = $self->resultset;
   my $item    = $rs->find(is_arrayref $item_id ? @{$item_id} : $item_id);

   $self->item(undef) unless $item;

   return $item;
}

sub build_source_name {
   return shift->item_class;
}

sub clear_model {
   my $self = shift;

   $self->item(undef);
   $self->item_id(undef);
   return;
}

sub get_source {
   my ($self, $accessor_path) = @_;

   return unless $self->schema;

   my $source = $self->source;

   return $source unless $accessor_path;

   my @accessors = split m{ \. }mx, $accessor_path;

   for my $accessor (@accessors) {
      $source = $self->_get_related_source($source, $accessor);

      throw "Unable to get source for ${accessor}" unless $source;
   }

   return $source;
}

sub init_value {
   my ($self, $field, $value) = @_;

   if (is_arrayref $value) {
      $value = [ map { $self->_fix_value($field, $_) } @{$value} ];
   }
   else { $value = $self->_fix_value($field, $value) }

   $field->init_value($value);
   $field->value($value);
   return;
}

sub lookup_options {
   my ($self, $field, $accessor_path) = @_;

   return unless $self->schema;

   my $self_source = $self->get_source($accessor_path);
   my $accessor    = $field->accessor;
   my ($f_class, $source);

   if ($self_source->has_relationship($accessor)) {
      $f_class = $self_source->related_class($accessor);
      $source  = $self->schema->source($f_class);
   }
   else {
      my $resultset  = $self_source->resultset;
      my $new_result = $resultset->new_result({});

      if ($new_result && $new_result->can("add_to_${accessor}")) {
         $source = $new_result->$accessor->result_source;
      }
   }

   return unless $source;

   my $label_column = $field->label_column;

   return unless $source->has_column($label_column)
      || $source->result_class->can($label_column);

   my $active_col = $self->active_column || $field->active_column;

   $active_col = NUL unless $source->has_column($active_col);

   my $sort_col = $field->sort_column;
   my ($primary_key) = $source->primary_columns;

   unless (defined $sort_col) {
      $sort_col = $source->has_column($label_column)
         ? $label_column : $primary_key;
   }

   my $criteria = {};

   if ($active_col) {
      my @or = ($active_col => TRUE);

      push @or, ("${primary_key}" => $field->init_value)
         if $self->item && defined $self->init_value;
      $criteria->{'-or'} = \@or;
   }

   my $rs   = $self->schema->resultset($source->source_name);
   my @rows = $rs->search($criteria, { order_by => $sort_col })->all;
   my @options;

   for my $row (@rows) {
      my $label = $row->$label_column;

      next unless defined $label;

      push @options, $row->id,
         $active_col && !$row->$active_col ? "[${label}]" : "${label}";
   }

   return \@options;
}

sub resultset {
   my $self = shift;

   throw 'You must supply a schema for your form' unless $self->schema;

   return $self->schema->resultset($self->source_name || $self->item_class);
}

sub set_item {
   my ($self, $item) = @_;

   return unless $item;

   my @primary_columns = $item->result_source->primary_columns;
   my $item_id;

   if (@primary_columns == 1) {
      $item_id = $item->get_column($primary_columns[0]);
   }
   elsif (@primary_columns > 1) {
      my @pks  = map { $_ => $item->get_columns($_) } @primary_columns;

      $item_id = [ { @pks }, { key => 'primary' } ];
   }

   if ($item_id) { $self->item_id($item_id) }
   else { $self->clear_item_id }

   $self->_set_item_class($item->result_source->source_name);
   $self->schema($item->result_source->schema);
   return;
}

sub set_item_id {
   my ($self, $item_id) = @_;

   if (defined $self->item) {
      $self->clear_item if !defined $item_id
         || (is_arrayref $item_id
             && join NUL, @{$item_id} ne join NUL, $self->item->id)
         || (ref \$item_id eq 'SCALAR' && $item_id ne $self->item->id);
   }

   return;
}

sub source {
   my ($self, $f_class) = @_;

   return $self->schema->source(
      $f_class || $self->source_name || $self->item_class
   );
}

sub unique_message_for_constraint {
   my ($self, $constraint) = @_;

   return $self->unique_messages->{$constraint}
      ||= 'Duplicate value for [_1] unique constraint';
}

sub update_model {
   my $self   = shift;
   my $item   = $self->item;
   my $source = $self->source;

   warn "HFs: update_model for ", $self->name, "\n" if $self->verbose;

   my %update_params = (
      resultset => $self->resultset,
      updates   => $self->values,
      %{ $self->rec_update_flags },
   );

   $update_params{object} = $self->item if $self->item;

   my $new_item;
   my $rec_update = \&DBIx::Class::ResultSet::RecursiveUpdate::Functions::recursive_update;

   $self->schema->txn_do(sub {
      $new_item = $rec_update->(%update_params);
      $new_item->discard_changes;
   });

   $self->item($new_item) if $new_item;

   return $self->item;
}

sub validate_model {
   return shift->validate_unique ? TRUE : FALSE;
}

sub validate_unique {
   my $self      = shift;
   my $rs        = $self->resultset;
   my $fields    = $self->fields;
   my @id_clause = ();
   my $found_error;

   @id_clause = _id_clause($rs, $self->item_id) if defined $self->item;

   my $value = $self->value;

   for my $field (@{$fields}) {
      next unless $field->unique;
      next if $field->is_inactive || !$field->has_result;
      next if $field->has_errors;

      my $value = $field->value;

      next unless defined $value;

      my $accessor = $field->accessor;
      my $count    = $rs->search({ $accessor => $value, @id_clause })->count;

      next if $count < 1;

      my $field_error = $field->get_message('unique')
         || $field->unique_message || 'Duplicate value for [_1]';

      $field->add_error($field_error, $field->loc_label);
      $found_error++;
   }

   for my $constraint (@{$self->unique_constraints}) {
      my @columns = $rs->result_source->unique_constraint_columns($constraint);
      my $field;

      for my $col (@columns) {
         ($field) = grep { $_->accessor eq $col } @{$fields};
         last if $field;
      }

      next unless defined $field;
      next if $field->has_unique;

      my @values = map {
         (exists $value->{$_} ? $value->{$_} : undef)
            || ($self->item ? $self->item->get_column($_) : undef) } @columns;

      next if @columns != @values;
      next if grep { !defined $_ } @values;

      my %where;

      @where{@columns} = @values;

      my $count = $rs->search(\%where)->search({@id_clause})->count;

      next if $count < 1;

      my $field_error = $self->unique_message_for_constraint($constraint);

      $field->add_error($field_error, $constraint);
      $found_error++;
   }

   return $found_error;
}

sub _build_rec_update_flags {
   return { unknown_params_ok => TRUE };
}

sub _fix_value {
   my ($self, $field, $value) = @_;

   return blessed $value && $value->isa('DBIx::Class') ? $value->id : $value;
}

sub _get_related_source {
   my ($self, $source, $name) = @_;

   return $source->related_source($name) if $source->has_relationship($name);

   my $row = $source->resultset->new({});

   return unless $row->can($name) && $row->can('add_to_' . $name)
      && $row->can('set_' . $name);

   return $row->$name->result_source;
}

sub _id_clause {
   my ($rs, $id) = @_;

   my @pks = $rs->result_source->primary_columns;
   my %clause;

   if (scalar @pks > 1) {
      throw 'Multiple primary keys are invalid' if !is_arrayref $id;

      my $cond = $id->[0];
      my @phrase;

      for my $col (keys %{$cond}) {
         $clause{$col} = { '!=' => $cond->{$col} };
      }
   }
   else { %clause = ($pks[0] => { '!=' => $id }) }

   return %clause;
}

use namespace::autoclean;

1;

__END__

=pod

=encoding utf-8

=head1 Name

HTML::Forms::Role::Model::DBIC - One-line description of the modules purpose

=head1 Synopsis

   use HTML::Forms::Role::Model::DBIC;
   # Brief but working code examples

=head1 Description

=head1 Configuration and Environment

Defines the following attributes;

=over 3

=back

=head1 Subroutines/Methods

=head1 Diagnostics

=head1 Dependencies

=over 3

=item L<Class::Usul>

=back

=head1 Incompatibilities

There are no known incompatibilities in this module

=head1 Bugs and Limitations

There are no known bugs in this module. Please report problems to
http://rt.cpan.org/NoAuth/Bugs.html?Dist=HTML-Forms-Model-DBIC.
Patches are welcome

=head1 Acknowledgements

Larry Wall - For the Perl programming language

=head1 Author

Peter Flanigan, C<< <lazarus@roxsoft.co.uk> >>

=head1 License and Copyright

Copyright (c) 2023 Peter Flanigan. All rights reserved

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself. See L<perlartistic>

This program is distributed in the hope that it will be useful,
but WITHOUT WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE

=cut

# Local Variables:
# mode: perl
# tab-width: 3
# End:
# vim: expandtab shiftwidth=3:
