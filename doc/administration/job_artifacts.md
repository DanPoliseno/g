# Jobs artifacts administration

>**Notes:**
>- Introduced in GitLab 8.2 and GitLab Runner 0.7.0.
>- Starting with GitLab 8.4 and GitLab Runner 1.0, the artifacts archive format
   changed to `ZIP`.
>- Starting with GitLab 8.17, builds are renamed to jobs.
>- This is the administration documentation. For the user guide see
   [pipelines/job_artifacts](../user/project/pipelines/job_artifacts.md).

Artifacts is a list of files and directories which are attached to a job
after it completes successfully. This feature is enabled by default in all
GitLab installations. Keep reading if you want to know how to disable it.

## Disabling job artifacts

To disable artifacts site-wide, follow the steps below.

---

**In Omnibus installations:**

1. Edit `/etc/gitlab/gitlab.rb` and add the following line:

    ```ruby
    gitlab_rails['artifacts_enabled'] = false
    ```

1. Save the file and [reconfigure GitLab][] for the changes to take effect.

---

**In installations from source:**

1. Edit `/home/git/gitlab/config/gitlab.yml` and add or amend the following lines:

    ```yaml
    artifacts:
      enabled: false
    ```

1. Save the file and [restart GitLab][] for the changes to take effect.

## Storing job artifacts

After a successful job, GitLab Runner uploads an archive containing the job
artifacts to GitLab.

### Using local storage

To change the location where the artifacts are stored locally, follow the steps
below.

---

**In Omnibus installations:**

_The artifacts are stored by default in
`/var/opt/gitlab/gitlab-rails/shared/artifacts`._

1. To change the storage path for example to `/mnt/storage/artifacts`, edit
   `/etc/gitlab/gitlab.rb` and add the following line:

    ```ruby
    gitlab_rails['artifacts_path'] = "/mnt/storage/artifacts"
    ```

1. Save the file and [reconfigure GitLab][] for the changes to take effect.

---

**In installations from source:**

_The artifacts are stored by default in
`/home/git/gitlab/shared/artifacts`._

1. To change the storage path for example to `/mnt/storage/artifacts`, edit
   `/home/git/gitlab/config/gitlab.yml` and add or amend the following lines:

    ```yaml
    artifacts:
      enabled: true
      path: /mnt/storage/artifacts
    ```

1. Save the file and [restart GitLab][] for the changes to take effect.

### Using object storage

In [GitLab Enterprise Edition Premium][eep] you can use an object storage like
AWS S3 to store the artifacts.

[Learn how to use the object storage option.][ee-os]

## Expiring artifacts

If an expiry date is used for the artifacts, they are marked for deletion
right after that date passes. Artifacts are cleaned up by the
`expire_build_artifacts_worker` cron job which is run by Sidekiq every hour at
50 minutes (`50 * * * *`).

To change the default schedule on which the artifacts are expired, follow the
steps below.

---

**In Omnibus installations:**

1. Edit `/etc/gitlab/gitlab.rb` and comment out or add the following line

    ```ruby
    gitlab_rails['expire_build_artifacts_worker_cron'] = "50 * * * *"
    ```

1. Save the file and [reconfigure GitLab][] for the changes to take effect.

---

**In installations from source:**

1. Edit `/home/git/gitlab/config/gitlab.yml` and add or amend the following
   lines:

    ```yaml
    expire_build_artifacts_worker:
      cron: "50 * * * *"
    ```

1. Save the file and [restart GitLab][] for the changes to take effect.

## Set the maximum file size of the artifacts

Provided the artifacts are enabled, you can change the maximum file size of the
artifacts through the [Admin area settings](../user/admin_area/settings/continuous_integration.md#maximum-artifacts-size).

## Storage statistics

You can see the total storage used for job artifacts on groups and projects
in the administration area, as well as through the [groups](../api/groups.md)
and [projects APIs](../api/projects.md).

## Implementation details

When GitLab receives an artifacts archive, an archive metadata file is also
generated. This metadata file describes all the entries that are located in the
artifacts archive itself. The metadata file is in a binary format, with
additional GZIP compression.

GitLab does not extract the artifacts archive in order to save space, memory
and disk I/O. It instead inspects the metadata file which contains all the
relevant information. This is especially important when there is a lot of
artifacts, or an archive is a very large file.

When clicking on a specific file, [GitLab Workhorse] extracts it
from the archive and the download begins. This implementation saves space,
memory and disk I/O.

[reconfigure gitlab]: restart_gitlab.md "How to restart GitLab"
[restart gitlab]: restart_gitlab.md "How to restart GitLab"
[gitlab workhorse]: https://gitlab.com/gitlab-org/gitlab-workhorse "GitLab Workhorse repository"
[ee-os]: https://docs.gitlab.com/ee/administration/job_artifacts.html#using-object-storage
[eep]: https://about.gitlab.com/gitlab-ee/ "GitLab Enterprise Edition Premium"
