#!/bin/bash
set -ev

export PATH="/c/Python37;$PATH"
cd /c/pthreads4w-code && nmake all install
