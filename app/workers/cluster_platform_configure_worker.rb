# frozen_string_literal: true

class ClusterPlatformConfigureWorker
  include ApplicationWorker
  include ClusterQueue

  def perform(cluster_id)
    Clusters::Cluster.find_by_id(cluster_id).try do |cluster|
      Clusters::RefreshService.new.create_or_update_namespaces_for_cluster(cluster)
    end
  end
end
