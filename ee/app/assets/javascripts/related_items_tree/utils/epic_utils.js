import createGqClient from '~/lib/graphql';

import { ChildType, PathIdSeparator } from '../constants';

export const gqClient = createGqClient(
  {},
  {
    cacheConfig: {
      addTypename: false,
    },
  },
);

/**
 * Returns formatted child item to include additional
 * flags and properties to use while rendering tree.
 * @param {Object} item
 */
export const formatChildItem = item =>
  Object.assign({}, item, {
    pathIdSeparator: PathIdSeparator[item.type],
  });

/**
 * Returns formatted array of Epics that doesn't contain
 * `edges`->`node` nesting
 *
 * @param {Array} children
 */
export const extractChildEpics = children =>
  children.edges.map(({ node, epicNode = node }) =>
    formatChildItem({
      ...epicNode,
      fullPath: epicNode.group.fullPath,
      type: ChildType.Epic,
    }),
  );

/**
 * Returns formatted array of Assignees that doesn't contain
 * `edges`->`node` nesting
 *
 * @param {Array} assignees
 */
export const extractIssueAssignees = assignees =>
  assignees.edges.map(assigneeNode => ({
    ...assigneeNode.node,
  }));

/**
 * Returns formatted array of Issues that doesn't contain
 * `edges`->`node` nesting
 *
 * @param {Array} issues
 */
export const extractChildIssues = issues =>
  issues.edges.map(({ node, issueNode = node }) =>
    formatChildItem({
      ...issueNode,
      type: ChildType.Issue,
      assignees: extractIssueAssignees(issueNode.assignees),
    }),
  );

/**
 * Parses Graph query response and updates
 * children array to include issues within it
 * @param {Object} responseRoot
 */
export const processQueryResponse = ({ epic }) =>
  [].concat(extractChildIssues(epic.issues), extractChildEpics(epic.children));
