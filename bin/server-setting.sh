#!/bin/sh

#turn off power saving
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
