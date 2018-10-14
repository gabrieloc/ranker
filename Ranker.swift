//
//  Ranker.swift
//
//
//  Created by Gabriel O'Flaherty-Chan on 2018-10-14.
//

import AppKit
import Cocoa
import CreateML
import NaturalLanguage

let ignoreCache = false
let baseURL = URL(string: "https://www.reddit.com")!
let postFetchCount = 100
let perPostCommentCount = 500

enum NetworkError: Error {
	case requestError, corruptResponse
}

protocol Resource: Codable, Hashable {
}

protocol Response: Decodable {
}

struct Comment: Resource {
	let body: String?
	let score: Int?
	var replies: Node<Comment>?
	
	enum CodingKeys: String, CodingKey {
		case body, score, replies
	}
	
	public init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		body = try? container.decode(String.self, forKey: .body)
		score = try? container.decode(Int.self, forKey: .score)
		replies = try? container.decode(Node<Comment>.self, forKey: .replies)
	}
	
	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(body, forKey: .body)
		try container.encode(score, forKey: .score)
	}
}

struct Post: Resource {
	let title: String
	let text: String?
	let subreddit: String
	let id: String
	
	enum CodingKeys: String, CodingKey {
		case title
		case text = "selftext"
		case subreddit = "subreddit_name_prefixed"
		case id
	}
	
	var commentsPath: String {
		return [subreddit, "comments", id].joined(separator: "/")
	}
}

struct Node<T: Resource>: Codable, Hashable {
	struct Data: Codable, Hashable {
		struct Child: Codable, Hashable {
			let data: T
		}
		let children: [Child]?
	}
	let kind: String
	let data: Data
}

struct PostsResponse: Response {
	let postNode: Node<Post>
	
	var posts: [Post]? {
		return postNode.data.children?.map { $0.data }
	}
	
	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		postNode = try container.decode(Node<Post>.self)
	}
}

struct CommentsResponse: Response {
	let post: Post
	let flattenedComments: Set<Comment>
	
	public init(from decoder: Decoder) throws {
		var container = try decoder.unkeyedContainer()
		let postNode = try container.decode(Node<Post>.self)
		post = postNode.data.children!.first!.data
		
		let commentsNode = try container.decode(Node<Comment>.self)
		var aggregation = Set<Comment>()
		CommentsResponse.aggregateComments(in: commentsNode, aggregation: &aggregation)
		self.flattenedComments = aggregation
	}
	
	static func aggregateComments(in node: Node<Comment>?, aggregation: inout Set<Comment>) {
		node?.data.children?.forEach { child in
			aggregation.insert(child.data)
			aggregateComments(in: child.data.replies, aggregation: &aggregation)
		}
	}
}

protocol Endpoint {
	associatedtype R: Response
	var resourcePath: String { get }
	var queryItems: [URLQueryItem]? { get }
}

extension Endpoint {
	var queryItems: [URLQueryItem]? {
		return nil
	}
	
	var url: URL {
		let url = baseURL.appendingPathComponent("\(resourcePath).json")
		var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
		components.queryItems = queryItems
		return components.url!
	}
	
	func request(_ completion: @escaping ((R) throws -> Void)) {
		let decoder = JSONDecoder()
		
		let requestCompletion: ((Data?, URLResponse?, Error?) throws -> Void) = { (data, response, error) in
			guard let data = data else {
				throw error ?? NetworkError.requestError
			}
			let decoded = try decoder.decode(R.self, from: data)
			try completion(decoded)
		}
		let session = URLSession(configuration: .default)
		let task = session.dataTask(with: url, completionHandler: { (data, response, error) in
			try? requestCompletion(data, response, error)
		})
		task.resume()
	}
}

enum PostsEndpoint: String, Endpoint {
	typealias R = PostsResponse
	
	case hot, new, random, rising, top
	
	var resourcePath: String {
		return rawValue
	}
	
	var filename: String {
		return "reddit-comments-\(resourcePath)"
	}
	
	var queryItems: [URLQueryItem]? {
		return [
			URLQueryItem(name: "limit", value: String(postFetchCount))
		]
	}
}

struct CommentsEndpoint: Endpoint {
	typealias R = CommentsResponse
	
	enum Sort: String {
		case confidence, top, new, controversial, old, random, qa, live
	}
	
	let path: String
	let sort: Sort
	
	init(post: Post, sort: Sort) {
		self.path = post.commentsPath
		self.sort = sort
	}
	
	var resourcePath: String {
		return path
	}
	
	var queryItems: [URLQueryItem]? {
		return [
			URLQueryItem(name: "sort", value: sort.rawValue),
			URLQueryItem(name: "limit", value: String(perPostCommentCount))
		]
	}
}

func aggregateComments(in postsEndpoint: PostsEndpoint, _ completion: @escaping (([Comment]) throws -> Void)) throws {
	let sort: CommentsEndpoint.Sort = .controversial
	
	print("aggregating comments from \(postFetchCount) posts in \"\(postsEndpoint.resourcePath)\" sorted by \"\(sort.rawValue)\"")
	
	postsEndpoint.request { postResponse throws in
		var aggregatedComments = [Comment]()
		var postsQueue: Set<Post> = Set(postResponse.posts ?? [])
		
		let pc = postResponse.posts?.count ?? 0
		
		postResponse.posts?.forEach { post in
			let commentsEndpoint = CommentsEndpoint(post: post, sort: .controversial)
			commentsEndpoint.request { commentsResponse in
				aggregatedComments += commentsResponse.flattenedComments
				postsQueue.remove(post)
				print(
					"""
					\(commentsResponse.flattenedComments.count) comments in \(post.commentsPath) (\(pc - postsQueue.count)/\(pc))
					"""
				)
				if postsQueue.isEmpty {
					try completion(aggregatedComments)
				}
			}
		}
	}
}

let currentDir = URL(string: FileManager.default.currentDirectoryPath)!

func fileURL(named name: String) -> URL {
	return URL(string: "file://\(currentDir.absoluteString)")!.appendingPathComponent(name)
}

@discardableResult
func encodeComments(_ comments: [Comment], exportDescription: String) throws -> URL {
	let exportURL = fileURL(named: exportDescription)
	print("writing comments to \(exportURL)")
	let encoder = JSONEncoder()
	let export = try encoder.encode(comments)
	do {
		try export.write(to: exportURL, options: [])
	} catch (let e ) {
		print(e)
	}
	print("🍒 wrote comment data to \(exportURL)")
	return exportURL
}

func encodeModel(_ model: MLTextClassifier, metadata: MLModelMetadata, name: String) throws -> URL {
	let buildURL = fileURL(named: "\(name).mlmodel")
	try model.write(to: buildURL, metadata: metadata)
	print("🍇 encoded model to \(buildURL)")
	return buildURL
}

func trainModel(with url: URL, contentType: String) throws -> (MLTextClassifier, MLModelMetadata) {
	let data = try MLDataTable(contentsOf: url)
	print(data, url)
	let (trainingData, testingData) = data.randomSplit(by: 0.8, seed: 5)
	let classifier = try MLTextClassifier(
		trainingData: trainingData,
		textColumn: "body",
		labelColumn: "score"
	)
	let evalMetrics = classifier.evaluation(on: testingData)
	
	print("🍏 training accuracy: \((1.0 - classifier.trainingMetrics.classificationError) * 100)%")
	print("🍎 validation accuracy: \((1.0 - classifier.validationMetrics.classificationError) * 100)%")
	print("🍊 evaluation accuracy: \((1.0 - evalMetrics.classificationError) * 100)%")
	
	let metadata = MLModelMetadata(
		author: "🐴",
		shortDescription: "Ranked Reddit comments from \"\(contentType)\"",
		license: nil,
		version: "9000.1",
		additional: nil
	)
	
	return (classifier, metadata)
}

func prepareTrainingData(_ completion: @escaping (() throws -> Void)) throws {
	try aggregateComments(in: endpoint) { (comments) in
		print("\(comments.count) comments found")
		try encodeComments(comments, exportDescription: endpoint.filename + ".json")
		try completion()
	}
}

extension Int {
	var reaction: String {
		let text: String = {
			switch self {
			case -Int.max..<0:
				return "🤮🤮👎👎👎 Don't even think about it"
			case 0..<5:
				return "🤨👎👎 Nah son"
			case 5..<20:
				return "🙃👎 Could be better.."
			case 20..<100:
				return "🙂👍 Not bad!"
			case 100..<300:
				return "🤩👍👍👍 Wow Wow!!!!"
			case 300..<Int.max:
				return "🤩🤩🤩✨👍✨🎉✨✨✨✨ AHHHHHHHH!!!!!!!!!"
			default:
				return "😶"
			}
		}()
		let arrow = self == 0 ? "" : (self > 0 ? "↑" : "↓")
		return "[\(arrow)\(self)] \(text)"
	}
}

func beginInput(calculateScore: ((String) -> Int)) {
	while let line = readLine(strippingNewline: true) {
		let score = calculateScore(line)
		print("\(score.reaction)")//, terminator: "\r")
		print("✏ ", terminator: "")
	}
}

@discardableResult
func createModel(with dataURL: URL) throws -> URL {
	print("👀 using data at \(dataURL)")
	let (model, metadata) = try trainModel(with: dataURL, contentType: endpoint.resourcePath)
	let url = try encodeModel(model, metadata: metadata, name: endpoint.filename)
	return url
}

func loadModel(at modelURL: URL) throws {
	print("👀 loading model at \(modelURL)")
	let compiledURL = try MLModel.compileModel(at: modelURL)
	let model = try NLModel(contentsOf: compiledURL)
	print("✅ Begin typing")
	print("✏ ", terminator: "")
	beginInput(
		calculateScore: { text in
			let label = model.predictedLabel(for: text)
			return Int(label ?? "0") ?? 0
		}
	)
}

let endpoint = PostsEndpoint.top

func main() throws {
	if ignoreCache {
		try prepareTrainingData {
			try main()
		}
		return
	}
	
	let modelURL = fileURL(named: "\(endpoint.filename).mlmodel")
	let dataURL = fileURL(named: "\(endpoint.filename).json")
	
	if FileManager.default.fileExists(atPath: modelURL.path) {
		try loadModel(at: modelURL)
	} else if FileManager.default.fileExists(atPath: dataURL.path) {
		try createModel(with: dataURL)
		try loadModel(at: modelURL)
	} else {
		try prepareTrainingData {
			try createModel(with: dataURL)
			try loadModel(at: modelURL)
		}
	}
}

do {
	try main()
} catch (let error) {
	print("‼️", error)
	exit(1)
}

dispatchMain()
