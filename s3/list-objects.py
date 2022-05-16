#!/usr/bin/env python3
#
# MIT License
#
# (C) Copyright 2021-2022 Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#

import boto3
import json

from argparse import ArgumentParser
from subprocess import Popen, PIPE


endpoint_url = 'http://rgw-vip'

def get_creds():
    p = Popen(['radosgw-admin', 'user', 'info', '--uid', 'STS'], universal_newlines=True, stdout=PIPE)
    output, error = p.communicate()
    if p.returncode != 0:
        sys.exit(1)
    info = json.loads(output)
    a_key = info['keys'][0]['access_key']
    s_key = info['keys'][0]['secret_key']
    return a_key, s_key

def main():

    parser = ArgumentParser(description='Lists objects in a bucket')
    parser.add_argument('--bucket-name',
                        dest='bucket_name',
                        action='store',
                        required=True,
                        help='the name of the bucket to list')
    args = parser.parse_args()
    a_key, s_key = get_creds()
    s3 = boto3.client('s3',
                      endpoint_url=endpoint_url,
                      aws_access_key_id=a_key,
                      aws_secret_access_key=s_key)

    response = s3.list_objects_v2(Bucket=args.bucket_name)

    if 'Contents' in response:
        for item in response['Contents']:
            print(item['Key'])
    else:
        print("Bucket is empty.")

if __name__ == '__main__':
    main()
