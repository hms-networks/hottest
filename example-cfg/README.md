Example walkthrough based on this folder
========================================

This readme clarifies on the steps and order followed to create this
"example-cfg" folder. Every subsection will just explain the work already done
here.

You may need to have a Jenkins instance running if you are going to run
commands against the server instead of just reading:

> JENKINS_HOME=<hottest JENKINS_HOME> java -jar jenkins.war --httpPort=8080

For devs. New major added features should be demoed here.

Folder structure
----------------

This folder has the structure below as you have seen.

├── chunks\
│   ├── board\
│   └── test\
├── parametrization\
│   ├── board\
│   └── test\
├── pipelines\
└── sync\

* Chunks: Contains chunks, the basic test unit snippets, which consist of a
".sh" and ".json" file each. They are used to generate Jenkins build jobs an
Jenkins nodes (tests and boards respectively).

* Parametrization: Contains json files used to do parameter overrides for
already defined Jenkins test/nodes.

* Pipelines: Contains json files for generating Jenkins pipelines. Used to
replicate test plans.

* Sync: Contains json files for the "sync" script; the tool that synchronizes
multiple nodes, build jobs and pipelines definitions with a Jenkins master.

Note that the root of this folder structure can be passed directly to the
"-I,--include" flag of sync, so we avoid passing the "chunks",
"parametrization" and "pipelines" subdirectories as individual include flags.

Test creation
-------------

We start with the chunk present on "chunks/test", which consists of two files:
"dummy-test.sh" and "dummy-test.json".

If we open "dummy-test.json" we see all the data defined for generating a
Jenkins job: description, test-labels and build job parameters.

Note that the "test-labels" property is empty. "test-labels" is used to define
Jenkins build job labels. A job will only be able to run on a node (board)
that has all these Jenkins labels defined. On this chunk it's deliberately left
empty, as there are ways to add labels on later stages.

For the ".sh" part ("dummy-test.sh") the explanation is done in the comments of
that file. We won't duplicate it here.

Board creation
--------------

Now that we have defined a generic test that can run on any board, we need to be
able to generate the board code for it, as every Jenkins build job (test)
deliberately contains the board code itself (deliberately).

If we take a look at "chunks/board" we find the "dummyboard" chunk
consists of a ".json" and ".sh" part as usual.

If we look at the ".json" part on "dummyboard.json" we see that
the fields for generating a Jenkins build node (board):
"description", "node-labels" and "environment-variables".

Any board gets automatically a Jenkins label for it name and another one for its
board type. The board type label is extracted from the filename without
extension of the board chunk; "dummyboard" on this case, so a test willing to
only run on this board type has to define the "dummyboard" test label (on the
"label" property of a test or through other means as we will see later).

"node-labels" contains the "mylabel" entry for demo purposes, here yoy would add
extra features of the board, e.g. if you have it connected to a network you
could add a "connected-to-lan" flag, so tests that test network features could
run on this board but not on another which isn't "connected-to-lan".

"environment-variables" just defines "DUMMY_BOARD_ADDRESS", so every board of
this type will have this environment variable defined and ready to use on the
Jenkins script.

Chunks that use the "DUMMY_BOARD_ADDRESS" variable should invoke the generator
directive "#|board-require-env <DUMMY_BOARD_ADDRESS>" to validate the presence
of this environment variable at generation-time. You can see this done e.g. on
"board/includes/localhost-board.sh".

If we look at the ".sh" part of "dummyboard" type we see again that
the comments explain what is done. The included chunks are explained on comments
too and their ".json" part are trivial. Notice how "localhost-deployment.json"
can still add a Jenkins build job parameters ("dummy_bootloader" and
"dummy_img"); it is a regular chunk, so why shouldn't?

Now we have something: Job (test) and node (board) generation
-------------------------------------------------------------

With only the files we created we could generate XML for the jenkins API to
add/update nodes:

> ./scripts/cli/gen.py get-node-xml -n dummylocal-1 -c chunks -c example-cfg/chunks -b board/dummyboard
> ./scripts/cli/gen.py get-node-xml -n dummylocal-2 -c chunks -c example-cfg/chunks -b board/dummyboard

Or a test job:

> ./scripts/cli/gen.py get-job-xml -c chunks -c example-cfg/chunks -b board/dummyboard -t test/dummy-test -l anotherlabel

Or just peek at the Jenkins job shell script:

> ./scripts/cli/gen.py get-job-script -c chunks -c example-cfg/chunks -b board/dummyboard -t test/dummy-test -l anotherlabel

See the "Running with the Jenkins CLI" subsection on the "gen.py" appendix of
the root README.md file of this project if you are interested on how to send
the generated jobs/nodes to a server through the Jenkins API.

We still have a problem. If we e.g. want two different build nodes (boards) of
the "dummyboard" type with a different "DUMMY_BOARD_ADDRESS" environment
variable we need to edit manually on the Jenkins instance. This doesn't lead
well to automation. Parametrization solves this problem.

Parametrization
---------------

Parametrization is used to modify some properties already present on both
build jobs (tests) and build nodes (boards).

On "parameterization/test" we can see the "dummy-test-failing.json" and
"dummy-test-succeeding.json". Both are just changing the default value of a
Jenkins build job parameter by using the
"parameter-default-overrides" property.

Now we can pass the parametrization files to "gen.py" and verify that it does
actually change the default value.

> ./scripts/cli/gen.py get-job-xml -p example-cfg/parametrization/test/dummy-test-failing.json -c chunks -c example-cfg/chunks -b board/dummyboard -t test/dummy-test -l dummyboard > file1
> ./scripts/cli/gen.py get-job-xml -p example-cfg/parametrization/test/dummy-test-succeeding.json -c chunks -c example-cfg/chunks -b board/dummyboard -t test/dummy-test -l dummyboard > file2
> diff -u file1 file2

The same can be done for nodes. In this case we look at "parameterization/board"
and we see two files for different boards of the same dummy type: "dummylocal-1"
and "dummylocal-2". Both add an extra Jenkins build node label and set a
different value on the "DUMMY_BOARD_ADDRESS" environment variable for each of
them.

> ./scripts/cli/gen.py get-node-xml -p example-cfg/parametrization/board/dummylocal-1.json -c chunks -c example-cfg/chunks -b board/dummyboard -n dummylocal-1 > file1
> ./scripts/cli/gen.py get-node-xml -p example-cfg/parametrization/board/dummylocal-2.json -c chunks -c example-cfg/chunks -b board/dummyboard -n dummylocal-2 > file2
> diff -u file1 file2

Sync file
---------

Now we can generate tests, boards and parametrize them. This can already be
fully automated by scripts but it's very tedious to do by hand. We can go a
step further and automate the generation and synchronization (and backup) of all
the server jobs, nodes and pipelines. This is exactly what "sync.py" does, you
are to be dealing with "gen.py" directly very seldom.

You can peek at the sync file on "example-cfg/sync/localsetup.json". Ignore the
"pipelines" property for now.

Notice that both tests on the sync file add labels to run just on one of the
nodes, this is for demo purposes.

We can add/update everything on a Jenkins instance by running:

> scripts/cli/sync.py http://localhost:8080 $USER <your jenkins token> sync -f example-cfg/sync/localsetup.json -c chunks -I example-cfg  -r my-first-test-setup

Every "sync" operation backs up the current server state.

When writing sync files overridable values through parametrization can come from
three sources:

-The original definition on the ".json" chunk of the board/test.
-A parameterization file passed to sync on the "parametrization-files" property.
-Parameterization passed inline to sync on the "parametrization-inline"
 property.

This may be confusing sometimes. You can use the "--dry-run-metadata" in
combination with whitelists ("-w") to aid you developing and debugging
complex parameterizations.

> scripts/cli/sync.py http://localhost:8080 $USER <your jenkins token> sync -f example-cfg/sync/localsetup.json -c chunks -I example-cfg -r my-first-test-setup --dry-run-metadata -w succeeding\$

Pipelines
---------

We left the pipeline to be the last explained part on this section only because
it references the Jenkins build jobs (tests) by the names they are given on the
"sync" file.

There isn't a great deal of complexity in a pipeline. It's just a series of
build jobs that are all scheduled in some order. This allows to implement
test plans (daily, weekly, per-device, etc.).

The file lies on "example-cfg/pipelines/daily-dummy.json" and has comments.
