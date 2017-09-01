//
//  Actions-Update.swift
//  trailer
//
//  Created by Paul Tsochantaris on 26/08/2017.
//  Copyright © 2017 Paul Tsochantaris. All rights reserved.
//

import Foundation

extension Actions {

	static private func successOrAbort(_ query: Query) {
		successOrAbort([query])
	}

	static private func successOrAbort(_ queries: [Query]) {

		var success = true
		let group = DispatchGroup()
		for q in queries {
			group.enter()
			q.run { s in
				if !s { success = false }
				group.leave()
			}
		}
		group.wait()
		if !success { exit(1) }
	}

    static func failUpdate(_ message: String?) {
        printErrorMesage(message)
        log("[!Please provide one of the following options for 'update'!]")
        printOption(name: "all", description: "Update all items")
        log()
        log("[!Options for notifications:!]")
        printOption(name: "-n", description: "List new comments and reviews on items")
        log()
    }

    static func processUpdateDirective(_ list: [String]) {
        guard list.count > 1 else {
            failUpdate("Missing argument")
            return
        }

        let command = list[1]
        switch command {
        case "all":
            update()

        case "help":
            log()
            failUpdate(nil)

        default:
            failUpdate("Unknown argmument: \(command)")
        }
    }

    private static func update() {
		DB.load()
		log("Starting update...")
		config.totalQueryCosts = 0

		///////////////////////////////////////////////////////////////////////////////////////////////////////////

		let repositoryListQuery = Query(name: "Repos", rootElement:
			Group(name: "viewer", fields: [
				User.fragment,
				Group(name: "organizations", fields: [Org.fragmentWithRepos], usePaging: true),
				Group(name: "repositories", fields: [Repo.fragment], usePaging: true),
				Group(name: "watching", fields: [Repo.fragment], usePaging: true)
				]))
		successOrAbort(repositoryListQuery)

		///////////////////////////////////////////////////////////////////////////////////////////////////////////

        var prIdList = [String: String]()
        for p in PullRequest.allItems.values {
            if let r = p.repo, r.shouldSyncPrs {
                prIdList[p.id] = r.id
            }
        }

        var issueIdList = [String: String]()
        for i in Issue.allItems.values {
            if let r = i.repo, r.shouldSyncIssues {
                issueIdList[i.id] = r.id
            }
        }

		let itemIdParser = { (node: [AnyHashable : Any]) in

			guard let repoId = node["id"] as? String else {
				return
			}

			var syncPrs = true
			var syncIssues = true
			if let repo = Repo.allItems[repoId] {

				if repo.syncState == .none {
					return
				}

				switch repo.visibility {
				case .hidden:
					return
				case .onlyIssues:
					syncPrs = false
				case .onlyPrs:
					syncIssues = false
				case .visible:
					break
				}
			}

			if syncPrs, let section = node["pullRequests"] as? [AnyHashable : Any] {

				if let itemList = section["edges"] as? [[AnyHashable : Any]] {
					for p in itemList {
						let node = p["node"] as! [AnyHashable : Any]
						if let id = node["id"] as? String {
							prIdList[id] = repoId
							log(level: .debug, indent: 1, "Registered PR ID: \(id)")
						}
					}

				} else if let itemList = section["nodes"] as? [[AnyHashable : Any]] {
					for p in itemList {
						if let id = p["id"] as? String {
							prIdList[id] = repoId
							log(level: .debug, indent: 1, "Registered PR ID: \(id)")
						}
					}
				}
			}

			if syncIssues, let section = node["issues"] as? [AnyHashable : Any] {

				if let itemList = section["edges"] as? [[AnyHashable : Any]] {
					for p in itemList {
						let node = p["node"] as! [AnyHashable : Any]
						if let id = node["id"] as? String {
							issueIdList[id] = repoId
							log(level: .debug, indent: 1, "Registered Issue ID: \(id)")
						}
					}

				} else if let itemList = section["nodes"] as? [[AnyHashable : Any]] {
					for p in itemList {
						if let id = p["id"] as? String {
							issueIdList[id] = repoId
							log(level: .debug, indent: 1, "Registered Issue ID: \(id)")
						}
					}
				}
			}
		}

		let repoIds = Repo.allItems.values.flatMap { return $0.visibility == .hidden ? nil : $0.id }
		let itemQueries = Query.batching("Item IDs", fields: [Repo.prAndIssueIdsFragment], idList: repoIds, perNodeBlock: itemIdParser)
		successOrAbort(itemQueries)

        ///////////////////////////////////////////////////////////////////////////////////////////////////////////

		if prIdList.count > 0 {
			let prQueries = Query.batching("PRs", fields: [PullRequest.fragment], idList: Array(prIdList.keys))
			successOrAbort(prQueries)

			let prsMissingParents = PullRequest.allItems.values.filter { $0.repo == nil }
			for pr in prsMissingParents {
				let prId = pr.id
				log(level: .debug, indent: 1, "Detected missing parent for PR ID '\(prId)'")
				if let repoIdForPr = prIdList[prId], let repo = Repo.allItems[repoIdForPr] {
					log(level: .debug, indent: 1, "Determined parent should be Repo ID '\(repoIdForPr)'")
					if let parent = Parent(item: repo, field: "pullRequests") {
						var newPr = pr
						newPr.makeChild(of: parent, indent: 1)
						PullRequest.allItems[prId] = newPr
					}
				}
			}
		}

		if issueIdList.count > 0 {
			let issueQueries = Query.batching("Issues", fields: [Issue.fragment], idList: Array(issueIdList.keys))
			successOrAbort(issueQueries)

			let issuesMissingParents = Issue.allItems.values.filter { $0.repo == nil }
			for issue in issuesMissingParents {
				let issueId = issue.id
				log(level: .debug, indent: 1, "Detected missing parent for Issue ID '\(issueId)'")
				if let repoIdForIssue = issueIdList[issueId], let repo = Repo.allItems[repoIdForIssue] {
					log(level: .debug, indent: 1, "Determined parent should be Repo ID '\(repoIdForIssue)'")
					if let parent = Parent(item: repo, field: "issues") {
						var newIssue = issue
						newIssue.makeChild(of: parent, indent: 1)
						Issue.allItems[issueId] = newIssue
					}
				}
			}
		}

		///////////////////////////////////////////////////////////////////////////////////////////////////////////

		let itemIdsWithComments = Review.allItems.values.flatMap({ $0.syncState == .none || !$0.syncNeedsComments ? nil : $0.id })
            + PullRequest.allItems.values.flatMap({ $0.syncState == .none || !$0.syncNeedsComments ? nil : $0.id })
            + Issue.allItems.values.flatMap({ $0.syncState == .none || !$0.syncNeedsComments ? nil : $0.id })

		let commentQueries = Query.batching("Comments", fields: [
			Review.commentsFragment,
			PullRequest.commentsFragment,
			Issue.commentsFragment,
			], idList: itemIdsWithComments)

		successOrAbort(commentQueries)

		///////////////////////////////////////////////////////////////////////////////////////////////////////////

        let itemIdsWithReactions = Comment.allItems.values.flatMap({ ($0.syncState == .none || !$0.syncNeedsReactions) ? nil : $0.id })
            + PullRequest.allItems.values.flatMap({ ($0.syncState == .none || !$0.syncNeedsReactions) ? nil : $0.id })
            + Issue.allItems.values.flatMap({ ($0.syncState == .none || !$0.syncNeedsReactions) ? nil : $0.id })

		let reactionsQueries = Query.batching("Reactions", fields: [
                Comment.pullRequestReviewCommentReactionFragment,
                Comment.issueCommentReactionFragment,
                PullRequest.reactionsFragment,
                Issue.reactionsFragment
                ], idList: itemIdsWithReactions)

		successOrAbort(reactionsQueries)

		///////////////////////////////////////////////////////////////////////////////////////////////////////////

        let n: NotificationMode = (commandLineArgument(matching: "-n") != nil) ? .consoleCommentsAndReviews : .standard

        DB.save(purgeUntouchedItems: true, notificationMode: n)
        Notifications.processQueue()
		log("Update done.")
		log(level: .verbose, "Total update API cost: \(config.totalQueryCosts)")
		log(level: .verbose, "Remaining API limit: \(config.totalApiRemaining)")
	}
}
