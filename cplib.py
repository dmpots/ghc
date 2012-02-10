#!/usr/bin/env python3

import argparse
import sys
import shutil
import os

htrace_fibon_dir=os.path.join(os.environ['HOME'],
                              'Research','git','htrace-fibon')

def parse_args(args):
    parser = argparse.ArgumentParser()
    parser.add_argument('-b', '--benchmark', required=True,
                        help='destination benchmark')
    parser.add_argument('-d', '--htrace-dir', default=htrace_fibon_dir)
    parser.add_argument('files', nargs='+',
                        help='source files')

    return parser.parse_args(args)

def dest_file_name(fname):
    if fname.startswith('libraries'):
        i = fname.find('/')
        fname = fname[i+1:]

    fname = fname.replace('/', '_', 1)
    return fname.replace('/', '.')

if __name__ == "__main__":

    opts = parse_args(sys.argv[1:])
    files = opts.files #map(os.path.abspath, opts.files)
    destd = os.path.join(opts.htrace_dir, opts.benchmark+'-htrace', 'bitcode')
    
    for ll in files:
        if not os.path.exists(ll):
            print("ERROR: {} does not exist".format(ll))
            sys.exit(1)

    if (not os.path.exists(destd)):
        print("ERROR: {} does not exist".format(destd))
        sys.exit(1)

    print("Copying {} files to {}".format(len(files), destd))
    for ll in files:
        destf = dest_file_name(ll)
        print("{} => {}".format(ll, destf))

        dest = os.path.join(destd, destf)
        shutil.copyfile(ll, dest)
