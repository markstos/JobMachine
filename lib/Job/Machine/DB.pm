package Job::Machine::DB;

use strict;
use warnings;
use Carp qw/croak confess/;
use DBI;
use JSON::XS;

use constant QUEUE_PREFIX    => 'jm:';
use constant RESPONSE_PREFIX => 'jmr:';

sub new {
	my ($class, %args) = @_;
	croak "No connect information" unless $args{dbh} or $args{dsn};
	croak "invalid queue" if ref $args{queue} and ref $args{queue} ne 'ARRAY';

	$args{user}     ||= undef;
	$args{password} ||= undef;
	$args{db_attr}  ||= undef;
	$args{dbh}      ||= DBI->connect($args{dsn},$args{user},$args{password},$args{db_attr});
	$args{schema}   ||= 'jobmachine';
	return bless \%args, $class;
}

sub listen {
	my ($self, %args) = @_;
	my $queue = $args{queue} || return undef;

	my $prefix = $args{reply} ?  RESPONSE_PREFIX :  QUEUE_PREFIX;
	for my $q (ref $queue ? @$queue : ($queue)) {
		$self->{dbh}->do(qq{listen "$prefix$q";});
	}
}

sub unlisten {
	my ($self, %args) = @_;
	my $queue = $args{queue} || return undef;

	my $prefix = $args{reply} ?  RESPONSE_PREFIX :  QUEUE_PREFIX;
	for my $q (ref $queue ? @$queue : ($queue)) {
		$self->{dbh}->do(qq{unlisten "$prefix$q";});
	}
}

sub notify {
	my ($self, %args) = @_;
	my $queue = $args{queue} || return undef;
	my $payload = $args{payload};
	my $prefix = $args{reply} ?  RESPONSE_PREFIX :  QUEUE_PREFIX;
	$queue = $prefix . $queue;
	my $sql = qq{SELECT pg_notify(?,?)};
	my $task = $self->select_first(
		sql => $sql,
		data => [ $queue, $payload],
	);
}

sub get_notification {
    my $self = shift;
	my $notifies = $self->dbh->func('pg_notifies');
	return $notifies;
}

sub set_listen {
	my ($self,$timeout) = @_;
	my $dbh = $self->dbh;
	my $notifies = $self->get_notification;
	if (!$notifies) {
		my $fd = $dbh->{pg_socket};
		vec(my $rfds='',$fd,1) = 1;
		my $n = select($rfds, undef, undef, $timeout);
		$notifies = $self->get_notification;
	}
	return $notifies || [0,0];
}

sub fetch_work_task {
	my $self = shift;
	my $queue = ref $self->{queue} ? $self->{queue} : [$self->{queue}];
	$self->{current_table} = 'task';
	my $elems = join(',', ('?') x @$queue);
	my $sql = qq{
		UPDATE
			"$self->{schema}".$self->{current_table} t
		SET
			status=100,
			modified=now()
		FROM
			"jobmachine".class cx
		WHERE
			t.class_id = cx.class_id
		AND
			task_id = (
				SELECT
					min(task_id)
				FROM
					"$self->{schema}".$self->{current_table} t
				JOIN
					"jobmachine".class c
				USING
					(class_id)
				WHERE
					t.status=0
				AND
					c.name IN ($elems)
				AND
					t.run_after IS NULL
				OR
					t.run_after > now()
			)
		AND
			t.status=0
		RETURNING
			*
		;
	};
	my $task = $self->select_first(
		sql => $sql,
		data => $queue
	) || return;

	$self->{task_id} = $task->{task_id};
	$self->{json} ||= JSON::XS->new;
	$task->{data} = $self->{json}->decode( delete $task->{parameters} );
	return $task;
}

sub insert_task {
	my ($self,$data,$queue) = @_;
	my $class = $self->fetch_class($queue);
	$self->{current_table} = 'task';
	$self->{json} ||= JSON::XS->new;
	my $frozen = $self->{json}->encode($data);
	my $sql = qq{
		INSERT INTO
			"$self->{schema}".$self->{current_table}
			(class_id,parameters,status)
		VALUES
			(?,?,?)
		RETURNING
			task_id
	};
	$self->insert(sql => $sql,data => [$class->{class_id},$frozen,0]);
}

sub set_task_status {
	my ($self,$status) = @_;
	my $id = $self->task_id;
	$self->{current_table} = 'task';
	my $sql = qq{
		UPDATE
			"$self->{schema}".$self->{current_table}
		SET
			status=?
		WHERE 
			task_id=?
	};
	$self->update(sql => $sql,data => [$status,$id]);
}

sub fetch_class {
	my ($self,$queue) = @_;
	$self->{current_table} = 'class';
	my $sql = qq{
		SELECT
			*
		FROM
			"$self->{schema}".$self->{current_table}
		WHERE
			name=?
	};
	return $self->select_first(sql => $sql,data => [$queue]) || $self->insert_class($queue);
}

sub insert_class {
	my ($self,$queue) = @_;
	my $sql = qq{
		INSERT INTO
			"$self->{schema}".$self->{current_table}
			(name)
		VALUES
			(?)
		RETURNING
			class_id
	};
	$self->select_first(sql => $sql,data => [$queue]);
}

sub insert_result {
	my ($self,$data,$queue) = @_;
	$self->{current_table} = 'result';
	$self->{json} ||= JSON::XS->new;
	my $frozen = $self->{json}->encode($data);
	my $sql = qq{
		INSERT INTO
			"$self->{schema}".$self->{current_table}
			(task_id,result)
		VALUES
			(?,?)
		RETURNING
			result_id
	};
	$self->insert(sql => $sql,data => [$self->{task_id},$frozen]);
}

sub fetch_result {
	my ($self,$id) = @_;
	$self->{current_table} = 'result';
	my $sql = qq{
		SELECT
			*
		FROM
			"$self->{schema}".$self->{current_table}
		WHERE
			task_id=?
		ORDER BY
			result_id DESC
	};
	my $result = $self->select_first(sql => $sql,data => [$id]) || return;

	$self->{json} ||= JSON::XS->new;
	return $self->{json}->decode($result->{result})->{data};
}

sub fetch_results {
	my ($self,$id) = @_;
	$self->{current_table} = 'result';
	my $sql = qq{
		SELECT
			*
		FROM
			"$self->{schema}".$self->{current_table}
		WHERE
			task_id=?
		ORDER BY
			result_id DESC
	};
	my $results = $self->select_all(sql => $sql,data => [$id]) || return;

	$self->{json} ||= JSON::XS->new;
	return [map { $self->{json}->decode($_->{result}) } @{ $results } ];
}

# 1. Find started tasks that have passed the time limit, most probably because 
# of a dead worker. (status 100, modified < now - max_runtime)
# 2. Trim status so task can be tried again

sub revive_tasks {
	my ($self,$max) = @_;
	$self->{current_table} = 'task';
	my $status = 100;
	my $sql = qq{
		UPDATE
			"$self->{schema}".$self->{current_table}
		SET
			status=0
		WHERE
			status=?
		AND
			modified < now() - INTERVAL '$max seconds'
	};
	my $result = $self->do(sql => $sql,data => [$status]);
	return $result;
}

# 1. Find tasks that have failed too many times (# of result rows > $self->retries
# 2. fail them (Set status 900)
# There's a hard limit (100) for how many tasks can be failed at one time for
# performance resons

sub fail_tasks {
	my ($self,$retries) = @_;
	$self->{current_table} = 'result';
	my $limit = 100;
	my $sql = qq{
		SELECT
			task_id
		FROM
			"$self->{schema}".$self->{current_table}
		GROUP BY
			task_id
		HAVING
			count(*)>?
		LIMIT ?
	};
	my $result = $self->select_all(sql => $sql,data => [$retries,$limit]) || return 0;
	return 0 unless @$result;

	my $task_ids = join ',',map {$_->{task_id}} @$result;
	$self->{current_table} = 'task';
	my $status = 900;
	$sql = qq{
		UPDATE
			"$self->{schema}".$self->{current_table}
		SET
			status=?
		WHERE
			task_id IN ($task_ids)
	};
	$self->do(sql => $sql,data => [$status]);
	return scalar @$result;
}

# 3. Find tasks that should be removed (remove_task < now)
# - delete them
# - log
sub remove_tasks {
	my ($self,$after) = @_;
	return 0 unless $after;

	$self->{current_table} = 'task';
	my $limit = 100;
	my $sql = qq{
		DELETE FROM
			"$self->{schema}".$self->{current_table}
		WHERE
			modified < now() - INTERVAL '$after days'
	};
	my $result = $self->do(sql => $sql,data => []);
	return $result;
}

sub select_first {
	my ($self, %args) = @_;
	my $sth = defined $args{sth} ? $args{sth} : $self->dbh->prepare($args{sql}) || return 0;

	unless($sth->execute(@{$args{data}})) {
		my @c = caller;
		print STDERR "File: $c[1] line $c[2]\n";
		print STDERR $args{sql}."\n" if($args{sql});
		return 0;
	}
	my $r = $sth->fetchrow_hashref();
	$sth->finish();
	return ( $r );
}

sub select_all {
	my ($self, %args) = @_;
	my $sth = defined $args{sth} ? $args{sth} : $self->dbh->prepare($args{sql}) || return 0;

	$self->set_bind_type($sth,$args{data});
	unless($sth->execute(@{$args{data}})) {
		my @c = caller;
		print STDERR "File: $c[1] line $c[2]\n";
		print STDERR $args{sql}."\n" if($args{sql});
		return 0;
	}
	my @result;
	while( my $r = $sth->fetchrow_hashref) {
			push(@result,$r);
	}
	$sth->finish();
	return ( \@result );
}

# XXX This function should be refactored to 
# avoid using names like "$data->[$i]->[0].
# ... it appears this routine has something to do with pairs of data
# but it's not clear what. 
# The DBI docs show that bind_param() usually takes a value to bind to as the second
# argument, but here that value is undef. 
sub set_bind_type {
	my ($self,$sth,$data) = @_;
	for my $i (0..scalar(@$data)-1) {
		next unless(ref($data->[$i]));

		$sth->bind_param($i+1, undef, $data->[$i]->[1]);
		$data->[$i] = $data->[$i]->[0];
	}
	return;
}


sub do {
	my ($self, %args) = @_;
	my $sth = defined $args{sth} ? $args{sth} : $self->dbh->prepare($args{sql}) || return 0;

	$sth->execute(@{$args{data}});
	my $rows = $sth->rows;
	$sth->finish();
	return $rows;
}

sub insert {
	my ($self, %args) = @_;
	my $sth = defined $args{sth} ? $args{sth} : $self->dbh->prepare($args{sql}) || return 0;

	$sth->execute(@{$args{data}});
	my $retval = $sth->fetch()->[0];
	$sth->finish();
	return $retval;
}

sub update {
	my $self = shift;
	$self->do(@_);
	return;
}

sub dbh {
	return $_[0]->{dbh} || confess "No database handle";
}

sub task_id {
	return $_[0]->{task_id} || confess "No task id";
}

sub disconnect {
	return $_[0]->{dbh}->disconnect if $_[0]->{dbh};
}

sub DESTROY {
	$_[0]->disconnect();
	return;
}

1;
__END__

=head1 NAME

Job::Machine::DB - Database class for Job::Machine

=head1 METHODS

=head2 new

  my $client = Job::Machine::DB->new(
	  dbh   => $dbh,
	  queue => 'queue.subqueue',

  );

  my $client = Job::Machine::Base->new(
	  dsn   => @dsn,
  );


=head2 set_listen

 $self->listen( queue => 'queue_name' );
 $self->listen( queue => \@queues, reply => 1  );

Sets up the listener.  Quit listening to the named queues. If 'reply' is
passed, we unlisten to the related reply queue instead of the task queue.

Return undef immediately if no queue is provided.

=head2 unlisten

 $self->unlisten( queue => 'queue_name' );
 $self->unlisten( queue => \@queues, reply => 1  );

Quit listening to the named queues. If 'reply' is passed, we unlisten
to the related reply queue instead of the task queue.

Return undef immediately if no queue is provided.

=head2 notify

 $self->notify( queue => 'queue_name' );
 $self->notify( queue => 'queue_name', reply => 1, payload => $data  );

Sends an asynchronous notification to the named queue, with an optional
payload. If 'reply' is true, then the queue names are taken to be reply.

Return undef immediately if no queue name is provided.

=head2 get_notification

 my $notifies = $self->get_notification();

Retrievies the pending notifications. The return value is an arrayref where
each row looks like this:

 my ($name, $pid, $payload) = @$notify;

=head2 set_listen

  my $notifies = $self->set_listen($timeout);

Starts listening for C<$timeout> seconds. Returns [0,0] if there are
no notifications ready for an arrayref of notifications if there are.
See get_notification above for the return value.

=head2 fetch_work_task

  while (my $task = $db->fetch_work_task) {

Fetch the next work task and return it, or undef there are no more tasks.
C< $task > is a hashref corresponding to a row in the tasks table, with the C< parameters >
value replaced with a C< data > value containing decoded JSON.

=head2 insert_task

 my $id = $db->insert_task($data,$queue);

Insert a Perl data structure into the named queue and return the task ID
inserted. The data structure is first encoded as JSON.

=head2 set_task_status

XXX Needs documentation

=head2 fetch_class

XXX Needs documentation

=head2 insert_class

XXX Needs documentation

=head2 insert_result

XXX Needs documentation

=head2 fetch_result

XXX Needs documentation

=head2 fetch_results

XXX Needs documentation

=head revive_tasks

XXX Needs documentation

=head2 fail_tasks

XXX Needs documentation

=head2 remove_tasks

XXX Needs documentation

=head2 select_first

XXX Needs documentation

=head2 select_all

XXX Needs documentation

=head2 set_bind_type

 $db->set_bind_type($sth,\@bind);

XXX Needs documentation.

=head2 do

 $rows = $self->do(sql => $sql,data => \@bind );
 $rows = $self->do(sth => $sth,data => \@bind );

Executes the SQL described by the C<< sql >> or C<< sth >> arguments, using an
arrayref of vind values passed to C<< data >>. Returns the number of rows
inserted or updated.

=head2 insert

 $retval = $self->insert(sql => $sql,data => \@bind );
 $retval = $self->insert(sth => $sth,data => \@bind );

Inserts the SQL described by the C<< sql >> or C<< sth >> arguments, using
an arrayref of vind values passed to C<< data >>.

=head2 update

 $db->update(sql => $sql,data => \@bind );

Behaves like L<< do >>, but doesn't return anything.

=head2 dbh

Return the database handle stored in the object, or die with a stack trace.

=head2 task_id

 my $task_id = $db->task_id;

Return a task_id stored in the object, or die with a stack trace if no task_id
is found.

=head2 disconnect

 $db->disconnect;

Disconnect from the database if it's connected.

=head2 DESTROY

Called automatically when the object goes out of scope. We simply disconnect
from the database at this time.

=cut
