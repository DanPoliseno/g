# frozen_string_literal: true

require 'spec_helper'

describe MergeTrains::RefreshMergeRequestsService do
  include ExclusiveLeaseHelpers

  let(:project) { create(:project) }
  set(:maintainer_1) { create(:user) }
  set(:maintainer_2) { create(:user) }
  let(:service) { described_class.new(project, maintainer_1) }

  before do
    project.add_maintainer(maintainer_1)
    project.add_maintainer(maintainer_2)
  end

  describe '#execute' do
    subject { service.execute(merge_request) }

    let!(:merge_request_1) do
      create(:merge_request, :on_train, train_creator: maintainer_1,
        source_branch: 'feature', source_project: project,
        target_branch: 'master', target_project: project)
    end

    let!(:merge_request_2) do
      create(:merge_request, :on_train, train_creator: maintainer_2,
        source_branch: 'signed-commits', source_project: project,
        target_branch: 'master', target_project: project)
    end

    let(:refresh_service_1) { double }
    let(:refresh_service_2) { double }

    before do
      allow(MergeTrains::RefreshMergeRequestService)
        .to receive(:new).with(project, maintainer_1) { refresh_service_1 }
      allow(MergeTrains::RefreshMergeRequestService)
        .to receive(:new).with(project, maintainer_2) { refresh_service_2 }
    end

    context 'when merge request 1 is passed' do
      let(:merge_request) { merge_request_1 }

      it 'executes RefreshMergeRequestService to all the following merge requests' do
        expect(refresh_service_1).to receive(:execute).with(merge_request_1)
        expect(refresh_service_2).to receive(:execute).with(merge_request_2)

        subject
      end

      context 'when merge request 1 is not on a merge train' do
        let(:merge_request) { merge_request_1 }
        let!(:merge_request_1) { create(:merge_request) }

        it 'does not refresh' do
          expect(refresh_service_1).not_to receive(:execute).with(merge_request_1)

          subject
        end
      end

      context 'when the other thread has already been processing the merge train' do
        let(:lock_key) { "batch_pop_queueing:lock:merge_trains:#{merge_request.target_project_id}:#{merge_request.target_branch}" }

        before do
          stub_exclusive_lease_taken(lock_key)
        end

        it 'does not refresh' do
          expect(refresh_service_1).not_to receive(:execute).with(merge_request_1)

          subject
        end

        it 'enqueues the merge request id to BatchPopQueueing' do
          expect_next_instance_of(Gitlab::BatchPopQueueing) do |queuing|
            expect(queuing).to receive(:enqueue).with([merge_request_1.id], anything).and_call_original
          end

          subject
        end
      end

      context 'when merge_trains_efficient_refresh is disabled' do
        before do
          stub_feature_flags(merge_trains_efficient_refresh: false)
        end

        context 'when the exclusive lock has already been taken' do
          let(:lease_key) do
            "merge_train:#{merge_request_1.target_project_id}-#{merge_request_1.target_branch}"
          end

          before do
            stub_exclusive_lease_taken(lease_key)
          end

          it 'raises FailedToObtainLockError' do
            expect { subject }.to raise_error(Gitlab::ExclusiveLeaseHelpers::FailedToObtainLockError)
          end
        end
      end
    end

    context 'when merge request 2 is passed' do
      let(:merge_request) { merge_request_2 }

      it 'executes RefreshMergeRequestService to all the following merge requests' do
        expect(refresh_service_1).not_to receive(:execute).with(merge_request_1)
        expect(refresh_service_2).to receive(:execute).with(merge_request_2)

        subject
      end

      context 'when merge request 1 was tried to be refreshed while the system is refreshing merge request 2' do
        before do
          allow_any_instance_of(described_class).to receive(:unsafe_refresh).with(merge_request_2) do
            service.execute(merge_request_1)
          end
        end

        it 'refreshes the merge request 1 later with AutoMergeProcessWorker' do
          expect(AutoMergeProcessWorker).to receive(:perform_async).with(merge_request_1.id).once

          subject
        end
      end
    end
  end
end