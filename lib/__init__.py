import os
import re
import json
import errno
import functions
from subprocess import call
from arguments import args
from shutil import copy
from sys import platform

COMMAND = 'ansible-playbook'
PARAMS = []
DIRS = {
    'self': os.path.abspath(os.path.dirname(os.path.dirname(__file__))),
    'project': args.project_dir if args.project_dir else os.environ.get('CIKIT_PROJECT_DIR'),
}

LOCALHOST = True
INSIDE_VM_OR_CI = True

if None is DIRS['project']:
    DIRS['project'] = os.getcwd()
    INSIDE_VM_OR_CI = False
elif not functions.is_project_root(DIRS['project']):
    functions.error('The "%s" directory does not store CIKit project.' % DIRS['project'], errno.ENOTDIR)

DIRS['cikit'] = DIRS['project'] + '/.cikit'
DIRS['scripts'] = DIRS['project' if INSIDE_VM_OR_CI else 'self'] + '/scripts'

if '' is args.playbook:
    functions.playbooks_print(DIRS['scripts'])

    if not INSIDE_VM_OR_CI:
        functions.playbooks_print(DIRS['self'], 'matrix/')

    exit(0)

PLAYBOOK = functions.playbooks_find(
    DIRS['scripts'] + '/' + args.playbook,
    # Load playbooks from non "scripts" directory within the CIKit package.
    DIRS['self'] + '/' + args.playbook,
    args.playbook,
)

if None is PLAYBOOK:
    functions.error('The "%s" command is not available.' % args.playbook, errno.ENFILE)

for line in open(PLAYBOOK):
    if re.search('^# requires-project-root$', line) and not functions.is_project_root(DIRS['project']):
        functions.error(
            'Execution of the "%s" is available only within the CIKit-project directory.' % args.playbook,
            errno.ENOTDIR,
        )

    # "ro" - is an acronym of the "required option".
    matches = re.search('^# ro:(.+?)$', line)

    if matches:
        option = matches.group(1)

        if option not in args.extra or not isinstance(args.extra[option], basestring) or len(args.extra[option]) < 2:
            functions.error(
                (
                    'The "--%s" option is required for the "%s" command and '
                    'currently missing or has a value less than 2 symbols.'
                )
                %
                (
                    option,
                    args.playbook
                ),
                errno.EPERM
            )

ENV_CONFIG = DIRS['cikit'] + '/environment.yml'

if os.path.isfile(ENV_CONFIG):
    ansible_executable = functions.call('which', COMMAND)

    if '' is ansible_executable:
        functions.warn(
            (
                'Cannot read environment configuration from "%s". Looks '
                'like Python setup cannot provide Ansible operability.'
            )
            %
            (
                ENV_CONFIG
            )
        )
    else:
        # It's an interesting trick for detecting Python interpreter. Sometimes it
        # may differ. Especially on MacOS, when Ansible installed via Homebrew. For
        # instance, "which python" returns the "/usr/local/Cellar/python/2.7.13/
        # Frameworks/Python.framework/Versions/2.7/bin/python2.7", but this particular
        # setup may not have necessary packages for full Ansible operability. Since
        # Ansible - is a Python scripts, they must have a shadebag line with a path
        # to interpreter they should run by. Grab it and try!
        # Given:
        #   $(realpath $(which python)) -c 'import yaml'
        # Ends by:
        #   Traceback (most recent call last):
        #     File "<string>", line 1, in <module>
        #   ImportError: No module named yaml
        # But:
        #   $(cat $(which "ansible-playbook") | head -n1 | tr -d '#!') -c 'import yaml'
        # Just works.
        with open(ansible_executable) as ansible_executable:
            args.extra.update(json.loads(
                functions.call(
                    ansible_executable.readline().lstrip('#!').rstrip(),
                    '-c',
                    'import yaml, json\nprint json.dumps(yaml.load(open(\'%s\')))' % ENV_CONFIG,
                )
            ))

# @todo Handle "EXTRA_VARS" environment variable.
# if 'EXTRA_VARS' in os.environ:
#     functions.parse_extra_vars(os.environ.get('EXTRA_VARS').split('--'), args.extra)

if 'ANSIBLE_INVENTORY' not in os.environ:
    INVENTORY_SRC = DIRS['cikit'] + '/inventory'
    INVENTORY_DEST = os.path.expanduser('~/.cikit-inventory')

    # Move "inventory" into user's home directory because it is not mounted file
    # system and can be affected via Linux commands ("chmod", "chown") under Windows.
    if os.path.isfile(INVENTORY_SRC):
        copy(INVENTORY_SRC, INVENTORY_DEST)

        if 0 is call(['chmod', 'a-x', INVENTORY_DEST]):
            PARAMS.append("-i '%s'" % INVENTORY_DEST)
            LOCALHOST = False
elif 'cygwin' is platform:
    os.environ['ANSIBLE_INVENTORY'] = functions.call('cygpath', "'%s'" % os.environ['ANSIBLE_INVENTORY'])
    LOCALHOST = False

if args.list_tags:
    PARAMS.append('--list-tags')

if args.tags:
    PARAMS.append("-t '%s'" % ','.join(args.tags))

if args.limit:
    PARAMS.append("-l '%s'" % args.limit)

if LOCALHOST:
    PARAMS.append("-i 'localhost,'")

if args.extra:
    PARAMS.append("-e '%s'" % json.dumps(args.extra))

PARAMS.append("-e __targetdir__='%s'" % DIRS['project'])

# https://github.com/sclorg/s2i-python-container/pull/169
os.environ['PYTHONUNBUFFERED'] = '1'
# https://github.com/ansible/ansible/blob/devel/lib/ansible/config/data/config.yml
os.environ['ANSIBLE_ROLES_PATH'] = DIRS['cikit'] + '/roles'
os.environ['ANSIBLE_FORCE_COLOR'] = '1'
os.environ['DISPLAY_SKIPPED_HOSTS'] = '0'
os.environ['ANSIBLE_RETRY_FILES_ENABLED'] = '0'

COMMAND = "%s '%s' %s" % (COMMAND, PLAYBOOK, ' '.join(PARAMS))

# Print entire command if verbosity requested.
if 'ANSIBLE_VERBOSITY' in os.environ:
    print COMMAND

# exit(call([COMMAND], shell=True, executable='/bin/bash'))