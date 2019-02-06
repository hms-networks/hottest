Hottest
=======

This is the "hottest" test project. Developed, but not limited, to testing
Linux-based firmware.

Motivation:

- Linaro's LAVA test framework was too big for our needs, a lot of resources
  were required for keeping us writing tests and up to date with the project
  (there was an API migration in place: old branch breakages). Some
  uncontributable features were missing too (e.g. flashing/testing bootloaders).

- We studied Fuego, but at the time it missed the ability to be used by multiple
  users on a single server: Fuego's GIT repository was mounted on the server
  filesystem, so two developers couldn't work at the same time on the same
  server safely.

Based on this previous experience with LAVA and taking a lot of inspiration from
our Fuego evaluations we realized that using Jenkins as a base (as Fuego does)
is an excellent idea.

Jenkins provides all the scheduling, interface (Web, REST, Python bindings), so
the heavy duty work is already done. This project is a simple Jenkins
customization/thin wrapper to turn it in a test server instead of a build
server.

We created this project with these goals:

- Modularity: Able to cope with almost any special requirement, as to to flash
  bootloaders with custom tools, flash NAND, etc.
- Simple and explicit. Prefer no smart tricks and clever setups.
- Customizable.
- Able to run tests on a developer machine with an already booted and flashed
  device.
- Easy to develop and debug tests with.
- Small code base.

For this we have to sacrifice at least one LAVA feature, multinode tests, which
is IMO a very good thing to do at least for our use case; multinode tests depend
on testing a DUT feature by using another DUT.

Design
======

Jenkins is used to build, we want to test only. For that we convert/refer to
some Jenkins entities with another name:

- Jenkins build job -> Test. A Jenkins job is a script, so we can power on and
  flash a board and run tests from them.

- Jenkins node -> Device board. We use a Jenkins node to represent a device
  board. Jenkins nodes are the entities that the Jenkins scheduler assigns
  jobs(to). We can have a farm of boards of the same type and by using Jenkins
  labels on both tests and boards just let Jenkins decide which board is free
  and available to run a job.

- Jenkins pipeline -> Test plan. A Jenkins pipeline in Groovy can be used to
  enqueue many existing build jobs in parallel. The pipeline can be a single job
  that that either fails or succeeds as a whole. Daily, weekly and by-device
  testplans are easily possible and can easily be remotely enqueued by using the
  existing jenkins REST API.

The design principles are:

- To allow the writing of reusable/shareable tests in a clear way (for Linux
  systems on Linux systems).

- To have a very small and manageable core and to leave all the device or LAB
  setup operations to the user integration phase.

- Reuse existing infrastructure for the Web interface, task scheduling and user
  management: Jenkins. Rationale: Don't reinvent the (boring) wheel.

- Prefer stock Jenkins while possible. No plugins. Rationale: Easy install and
  maintenance. Less 3rd party dependencies that can be break and need to be
  tracked. Easy version updates.

- Make all the test data to be contained on the test job itself (no
  indirections, no use of files on the host machine). Rationale: Ability to
  Debug and test fixes/modifications while using the Jenkins Web interface ONLY.
  Low cognitive load. Full view of the test. Ability to skip flashing and
  booting on a test that you are debugging locally, etc.

Requirements
============
Host
----

- GNU timeout
- gnuplot
- flock (if using locks)
- sshpass (if ssh transports are used).

Targets
-------

- For serial based communication through "serio": bash, even though having stat,
  md5sum and uuencode allows for safer file transfers.

Install
=======

> git submodule update --init --recursive

> sudo -H pip install python-jenkins xunitgen sshpass

> JENKINS_HOME=<your desired jenkins install dir> scripts/install/jenkins-prepare.sh

Follow the script's instructions.

Quick start
===========

This README is written as a reference guide. If you want to start tinkering in
a more practical way you may want to start on "example-cfg/README.md"

Building tests (Chunks)
=======================

Tests are built by joining pieces of shell code. The shell code has a companion
".json" file which contains metadata that configures some aspects of the Jenkins
job and nodes. Both the ".sh" and ".json" pair are called a test "chunk".

Tests are built by combining a "chunk" to generated the board code (power,
deployment, boot, etc) and a test "chunk" to generate the test code. As a
concept is very simple.

As we will see later, test "chunk"s can include (copy-paste) other test
"chunk"s, so boards can use a "mixin" of available features (e.g. serial
communication) without reimplementing them every time.

We effectively build tests by iterating a root board and a root test chunk. By
iterating we mean as following all the includes.

All chunks are equal on the shell ".sh" part, but the root board and root chunk
have extra properties on their json file as we will see later.

| chunk type | bash part | json part                 |
|------------|-----------|---------------------------|
| included   | standard  | standard                  |
| root board | standard  | standard + board specific |
| root test  | standard  | standard                  |

On the next sections, we define how the elements on the table above look.

Standard bash (.sh) part of a chunk
===================================

Syntax
------

The syntax is regular bash (without shebang) with three added in-comment
directives:

- "#|board-require-env <env-variable>": adds a generation-time check that the
  board node has defined an environment variable. This is used to avoid errors
  on testing (typos) and to document required environment variables on the node.
  This will be better understood later when looking at the "json" part of the
  root board chunk.

- "#|include <subpath>": pastes in place the content of another ".sh" chunk and
  combines the json chunks (parameters for Jenkins). The "subpath" value is
  always absolute to one of the chunk include directories on the generator
  script. It allows including the same chunk once and only once, so multiple
  chunks can include the same chunk without fear of code duplication or include
  recursion, the chunk will be pasted only on the first occurrence.

- "#|parameter-default-override <variable value>": Overrides the default value
  of a job parameter. The variable name is just unquoted text that matches the
  same naming rules than the C language variables. The value can contain spaces
  or some enclosing quotes (useful if the variable starts with space). The
  directive can override many times the same parameter, in that case it will be
  overridden to the last value found on the script iteration.

The syntax is short, but this alone doesn't give us enough to implement tests.
We need some type of test API/framework. So the objective of the chunks is to
allow implementing some standard functions that an internal framework will run.

Test API overview
-----------------

Every test (Jenkins job) consist of many steps. Steps are implemented and
provided to the framework on bash functions to run at some point of the test
sequence. The test sequence points are:

* dut_power_off
* before_dut_power_on
* dut_power_on
* after_dut_power_on
* dut_boot
* before_test_run
* test_run
* after_test_run
* dut_power_off
* before_exit

The name of the functions that add steps to the sequence are self explanatory,
only remarks are added when needed:

* add_step_before_dut_power_on

* add_step_after_dut_power_on

* add_step_before_test_run

* add_step_to_test_run: Here are added the functions that are intended to be
  actual test steps.

* add_step_after_test_run: Runs only if "test_run" was reached with the
  device still powered on.

* add_step_before_exit: Runs always. The device is powered off.

Note that returning non-zero from any step (function) on the sequence that
happens before "test_run" will interrupt further function execution.

If we want to reuse tests between boards we need the tests to provide abstracted
communication with the device. Each test (Jenkins job) has to implement all the
mandatory functions below:

* dut_cmd COMMAND: Run a command on the DUT, print stdout and stderr
  locally and return the output error code. e.g.

    dut_cmd echo "ls /home/my-dut-user-data"

* dut_put SOURCE DEST: Copy files to the device.

* dut_get SOURCE DEST: Copy files from the device.

Then there are some standardized power-related functions that may or may not be
implemented depending on the setup. Note that a test (Jenkins job) hast to
provide all or none of the next power-related functions listed below:

* dut_power_off: Power off the board.

* dut_power_on: Power on the board.

* dut_boot: Boots the system. When returning from this function "dut_cmd",
  "dut_get" and "dut_put" should be able to run.

Framework functions
-------------------

There are some utility functions provided by the framework. They live on
"chunks/runtime/header.sh". Most have documentation, so we won't duplicate it
here.

On this section we just briefly explain the functions that are related to the
test flow:

- declare_test_cases: This is to be called on the global script scope only, not
  inside functions. Declares the names of all the test cases that will run. This
  is to be able to generate a report naming the test cases that didn't run if
  e.g. some part of the Job's script raises a SIGTERM before the script was able
  to finish.

- test_case_set: Sets the result of a test based on an error code. E.g:

  > ls myfile
  > test_case_set myfile_available $?

- test_case_set_not: As "test_case_set", but succeeds on a failing error code.

From the Jenkins perspective a build job (test) only succeeds when all the test
cases passed, so the result is based on the "test_case_set" calls made, not on
the return code of "test_run".

Framework rules/properties/considerations
-----------------------------------------

When you write chunks you are as a matter of fact copy-pasting pieces of shell
code through the "include" directive. You are expected to write your shell code
inside those functions, as writing it outside on the global scope will write
code that run before the device is even powered on and the internal framework
has started.

You can define variables to be seen by all the functions of your chunk on the
global scope, but be aware that the framework will run all your functions as
subprocesses (to be able to implement timeouts transparently), so modifications
on variables won't be seen from the outside (other functions). We recommend to
qualify your global-scope variables as "readonly".

Then there are framework functions that require you to call them on the global
scope before the test starts (e.g. declare_test_cases).

Standard chunks's json part
===========================

This part adds metadata for the Jenkins job generator for adding e.g. the job
description, job labels, test parameters, etc.

All iterated chunks can contribute extra parameters.

You can find the json schema with field descriptions at:
"scripts/cli/_schema_chunk_test.json"


Root board's chunk json part
============================

The root board chunk's ".json" metadata is like a regular chunk, but it's used
to generate a Jenkins build node too, so it requires extra data e.g. labels.

You can find the json schema with field descriptions at:
"scripts/cli/_schema_chunk_board.json"


Parametrization (of the Jenkins job )
=====================================

With the ".json" parts of a chunk we define Jenkins properties for nodes and
tests.

Without the ability to parametrize tests or nodes at generation time we would be
required to duplicate chunks with different ".json" metadata for simple
customizations like e.g. having a build node (board) with a different IP address
value on a given Jenkins build node environment variable.

So as you may have expected, we have simple parametrization json files that
allow customizing some values on the resulting test jobs and build nodes.

The schema for the board and parametrization files are:
"scripts/cli/_schema_param_board.json" and "scripts/cli/_schema_param_test.json"


These files are fed to the generator script or defined on the synchronization
script definition file.

Pipelines (testplans)
=====================

Pipelines are just a list of jobs with their parameter values grouped to be
scheduled together. This helps implementing e.g. scheduled daily tests.

The json schema is found at: "scripts/cli/_schema_pipeline.json"


The synchronizer (sync.py)
==========================

We store the full definition of a server instance on files for the sync.py
script (scripts/cli/sync.py).

This allows to automate the file generation, deployment and update on a running
server and to run some validation that saves us from some mistakes at runtime.

As the synchronizer allows includes (-I), you can store tests, boards, etc. on
different repositories.

Sync
====

Sync files are the definition of a Jenkins server instance. They contain boards,
tests and pipelines. sync files are used by the "scripts/cli/sync.py" util to
back-up and update running Jenkins (hottest) instances.

They also use "gen.py" as a library so in theory you shouldn't need to interface
with "gen.py" directly.

The json schema is found at: "scripts/cli/_schema_sync.json"

This is a CLI tool with help, but there are two important considerations:

-Every board file, chunk file, parametrization file and pipeline file referenced
on the file are passed as suffixes for an include directory (as the C
preprocessor does). Relative paths are not allowed.

-Board and chunk files referenced on the file contain not extension. The other
 types of file do.

 Examples
 --------

> scripts/cli/sync.py http://localhost:8080 $USER <your jenkins token> sync -f example-cfg/sync/localsetup.json -c chunks -I example-cfg -r test --dry-run

Notice that we are using "-I" to include a folder with tests, pipelines, etc.
You can use as many includes as you want (as in a compiler), so you can store
tests, boards, etc on your own repositories. In this demo case we were just
including "example-cfg" that lives on this repo.

We are using --dry-run, so this command is not destructive. You will
see that a folder with a backup of the instance state before running the
command will appear on your current directory.

You can filter which blocks of the sync script run with "-m,--mode":

 't': tests, 'p': pipelines, 'n': nodes, 'b' backup

 So if you pass "-m np" you just synchronize nodes and pipelines, skipping the
 server backup and test synchroniation.

You can filter further with ,"-w,--item-whitelist". This parameter takes a regex
to filter. The filter applies on tests, nodes or pipelines and the flag can be
repeated to append many filters. This allows for e.g. to update single tests or
single nodes.

The "-r, --root-folder" parameter allows to generate all the Jenkins jobs under
a root folder. This parameter can be used e.g. for developing, keeping previous
versions of the tests, etc.

Recommendations when building tests
===================================

- Build tests as reusable as possible. Aim to place them on the chunks of
  hottest (hottest/chunks) and get them merged instead of in your chunk layers,
  so sharing is made possible.

- Build tests with few board dependencies. A test using a node (board)
  environment variable on the script is less reusable and less explicit than
  a test exposing such variable as a Jenkins parameter (with description).

  Jenkins variables understand the bash $VAR syntax, so a board variable can
  be used in a parameter while still keeping the test reusable by everyone.

- It is perfectly fine that a test has to use the value of board a environment
  variable. The Jenkins parameter can reference board environment variables
  with the "${YOUR_BOARD_ENVVAR}" syntax. Add the
  "#|board-require-env <YOUR_BOARD_ENVVAR>" clause to your test to do a runtime
  check.

Known issues
============
- Node deletion seems unstable, and node creation seems unstable. Sometimes
  Jenkins relaunching is required. NOTE: On my new install on 2018-11 I haven't
  found issues.

TODO
====

- Improve this README if required.

LOW PRIORITY

- Jenkins has locks (Lockable resource plugin). For now this feature isn't
  necessary for us because we have locks on code and serial executions on the
  pipelines, but this may come handy as soon as a test requires locking two
  resources. It may be slower than having very precise scheduled executions but
  complementary.
- Study test dependencies on pipelines, e.g. failing a whole chain of suites
  on the result of a third test (SDK).
- Test job labels as build parameters? Pros: less (automated) job repetition,
  Cons: results stored on the same Jenkins folder for all the label variants.
  Would need a custom way of storing results.
- Backing up job (test) results is required? (related to the queries thing,
  jenkins itself stores the results now).
- Extra labels is duplicated on sync-files, as they can be added both with
  "parametrization-inline" and the dedicated fields.

Appendix: The Generator (gen.py)
================================

The generator is located at "scripts/cli/gen.py". It's a CLI tool/module that
generates Jenkins XML definition files that can be used on the jenkins-cli.

Most of the time when developing you will interface with "sync.py", that loads
the generator as a module. You won't be using the CLI of the generator. It
was just created during development and left because it simplifies debugging.
You can skip directly yo the next "sync.py" section if you aren't interested on
the internals.

On this section's commands we use the environment variable $REPO_ROOT, which
contains the path to the root folder of this repository.

The generator commands are suffixed. The suffixes mean:

* xml: Generates xml to be consumed by the Jenkins API.

* metadata: Generates data to be consumed by humans or (hopefully) "grep". This
 is useful to e.g. easily see what the effects of the parametrization files are.

* script: Dumps only the generated script.

The generator supports the next subcommands:

get-node-[xml|metadata]
-----------------------

Gets a node/board.

> ./scripts/cli/gen.py get-node-xml -c chunks -c example-cfg/chunks/ -p example-cfg/parametrization/board/dummylocal-1.json -b board/dummyboard -n localhost1

Note that "-c" is called twice to add two chunk include directories.


get-job-[xml|metadata|script]
-----------------------------

Gets a test/job.

> ./scripts/cli/gen.py get-job-xml -c chunks -c example-cfg/chunks/ -p example-cfg/parametrization/test/dummy-test-succeeding.json -t test/dummy-test -b board/dummyboard -l localhost

Note that "-c" is called twice to add two chunk include directories.

"-l" adds a test label. Tests always need at least a test label to decide at
which type of executor they should run.

get-pipeline-[xml|metadata|script]
----------------------------------

Gets a testplan/pipeline.

> ./scripts/cli/gen.py get-pipeline-xml -p example-cfg/pipelines/daily-dummy.json


Running with the jenkins CLI
----------------------------

You can pipe the output of the commands above to the Jenkins cli like this. For
brevity we assume that they are stored in the file named "xmlfile":

> export JENKLINS_CLI="java -jar jenkins-cli.jar -s <jenkins_url> -auth <your user>:<your token>"
> cat xmlfile | $JENKLINS_CLI <CMD> <PARAMS>

So e.g to add a test or pipeline you do:

> cat xmlfile | $JENKLINS_CLI <create-job|update-job> <job/pipeline name>

To add a node:

> cat xmlfile | $JENKLINS_CLI <create-node|update-node> <node name>

This is unnecessary if you use the "--whitelist" flag of our "sync.py" script.

Note that if you are missing the "jenkins-cli.jar" file you can download it
with:

> wget <your-server-url>/jnlpJars/jenkins-cli.jar
