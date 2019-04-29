# frozen_string_literal: true

module Geo
  class JobArtifactRegistryFinder < RegistryFinder
    def count_syncable
      syncable.count
    end

    def count_synced
      if aggregate_pushdown_supported?
        find_synced.count
      else
        legacy_find_synced.count
      end
    end

    def count_failed
      if aggregate_pushdown_supported?
        find_failed.count
      else
        legacy_find_failed.count
      end
    end

    def count_synced_missing_on_primary
      if aggregate_pushdown_supported?
        find_synced_missing_on_primary.count
      else
        legacy_find_synced_missing_on_primary.count
      end
    end

    def count_registry
      Geo::JobArtifactRegistry.count
    end

    def syncable
      if use_legacy_queries_for_selective_sync?
        legacy_finder.syncable
      elsif selective_sync?
        job_artifacts.syncable
      else
        Ci::JobArtifact.syncable
      end
    end

    # Find limited amount of non replicated job artifacts.
    #
    # You can pass a list with `except_artifact_ids:` so you can exclude items you
    # already scheduled but haven't finished and aren't persisted to the database yet
    #
    # TODO: Alternative here is to use some sort of window function with a cursor instead
    #       of simply limiting the query and passing a list of items we don't want
    #
    # @param [Integer] batch_size used to limit the results returned
    # @param [Array<Integer>] except_artifact_ids ids that will be ignored from the query
    # rubocop: disable CodeReuse/ActiveRecord
    def find_unsynced(batch_size:, except_artifact_ids: [])
      relation =
        if use_legacy_queries?
          legacy_find_unsynced(except_artifact_ids: except_artifact_ids)
        else
          fdw_find_unsynced(except_artifact_ids: except_artifact_ids)
        end

      relation.limit(batch_size)
    end
    # rubocop: enable CodeReuse/ActiveRecord

    # rubocop: disable CodeReuse/ActiveRecord
    def find_migrated_local(batch_size:, except_artifact_ids: [])
      relation =
        if use_legacy_queries?
          legacy_find_migrated_local(except_artifact_ids: except_artifact_ids)
        else
          fdw_find_migrated_local(except_artifact_ids: except_artifact_ids)
        end

      relation.limit(batch_size)
    end
    # rubocop: enable CodeReuse/ActiveRecord

    # rubocop: disable CodeReuse/ActiveRecord
    def find_retryable_failed_registries(batch_size:, except_artifact_ids: [])
      find_failed_registries
        .retry_due
        .artifact_id_not_in(except_artifact_ids)
        .limit(batch_size)
    end
    # rubocop: enable CodeReuse/ActiveRecord

    # rubocop: disable CodeReuse/ActiveRecord
    def find_retryable_synced_missing_on_primary_registries(batch_size:, except_artifact_ids: [])
      find_synced_missing_on_primary_registries
        .retry_due
        .artifact_id_not_in(except_artifact_ids)
        .limit(batch_size)
    end
    # rubocop: enable CodeReuse/ActiveRecord

    private

    # rubocop:disable CodeReuse/Finder
    def legacy_finder
      @legacy_finder ||= Geo::LegacyJobArtifactRegistryFinder.new(current_node: current_node)
    end
    # rubocop:enable CodeReuse/Finder

    def fdw_geo_node
      @fdw_geo_node ||= Geo::Fdw::GeoNode.find(current_node.id)
    end

    def job_artifacts
      if selective_sync?
        Geo::Fdw::Ci::JobArtifact.project_id_in(fdw_geo_node.projects)
      else
        Geo::Fdw::Ci::JobArtifact.all
      end
    end

    def find_synced
      if use_legacy_queries?
        legacy_find_synced
      else
        fdw_find.merge(find_synced_registries)
      end
    end

    def find_synced_missing_on_primary
      if use_legacy_queries?
        legacy_find_synced_missing_on_primary
      else
        fdw_find.merge(find_synced_missing_on_primary_registries)
      end
    end

    def find_failed
      if use_legacy_queries?
        legacy_find_failed
      else
        fdw_find.merge(find_failed_registries)
      end
    end

    def find_synced_registries
      Geo::JobArtifactRegistry.synced
    end

    def find_synced_missing_on_primary_registries
      find_synced_registries.missing_on_primary
    end

    def find_failed_registries
      Geo::JobArtifactRegistry.failed
    end

    def fdw_find
      job_artifacts
        .inner_join_job_artifact_registry
        .syncable
    end

    def fdw_find_unsynced(except_artifact_ids:)
      job_artifacts
        .missing_job_artifact_registry
        .syncable
        .id_not_in(except_artifact_ids)
    end

    def fdw_find_migrated_local(except_artifact_ids:)
      job_artifacts
        .inner_join_job_artifact_registry
        .with_files_stored_remotely
        .id_not_in(except_artifact_ids)
        .merge(Geo::JobArtifactRegistry.all)
    end

    def legacy_find_synced
      legacy_inner_join_registry_ids(
        syncable,
        find_synced_registries.pluck_artifact_key,
        Ci::JobArtifact
      )
    end

    def legacy_find_failed
      legacy_inner_join_registry_ids(
        syncable,
        find_failed_registries.pluck_artifact_key,
        Ci::JobArtifact
      )
    end

    def legacy_find_unsynced(except_artifact_ids:)
      registry_artifact_ids = Geo::JobArtifactRegistry.pluck_artifact_key | except_artifact_ids

      legacy_left_outer_join_registry_ids(
        syncable,
        registry_artifact_ids,
        Ci::JobArtifact
      )
    end

    def legacy_find_migrated_local(except_artifact_ids:)
      registry_artifact_ids = Geo::JobArtifactRegistry.pluck_artifact_key - except_artifact_ids

      legacy_inner_join_registry_ids(
        legacy_finder.job_artifacts.with_files_stored_remotely,
        registry_artifact_ids,
        Ci::JobArtifact
      )
    end

    def legacy_find_synced_missing_on_primary
      legacy_inner_join_registry_ids(
        syncable,
        find_synced_missing_on_primary_registries.pluck_artifact_key,
        Ci::JobArtifact
      )
    end
  end
end
