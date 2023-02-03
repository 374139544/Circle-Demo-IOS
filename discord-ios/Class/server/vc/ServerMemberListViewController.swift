//
//  ServerMemberListViewController.swift
//  discord-ios
//
//  Created by 冯钊 on 2022/11/23.
//

import UIKit
import MJRefresh
import HyphenateChat

class ServerMemberListViewController: BaseViewController {

    @IBOutlet private weak var tableView: UITableView!
    private let showType: ServerStratum
    
    private var result: EMCursorResult<EMCircleUser>?
    private var role: EMCircleUserRole?
    private var muteStateMap: [String: NSNumber]?
    private let userOnlineStateCache = UserOnlineStateCache()
    
    init(showType: ServerStratum) {
        self.showType = showType
        super.init(nibName: nil, bundle: nil)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        switch self.showType {
        case .server:
            self.title = "社区成员"
        case .channel:
            self.title = "频道成员"
        }
        
        self.tableView.register(UINib(nibName: "ServerMemberTableViewCell", bundle: nil), forCellReuseIdentifier: "cell")
        self.tableView.tableFooterView = UIView()
        self.tableView.mj_header = MJRefreshNormalHeader(refreshingBlock: { [weak self] in
            self?.loadData(refresh: true)
        })
        self.tableView.mj_footer = MJRefreshAutoNormalFooter(refreshingBlock: { [weak self] in
            self?.loadData(refresh: false)
        })
        
        self.tableView.mj_header?.beginRefreshing()
        
        switch self.showType {
        case .server(serverId: let serverId), .channel(serverId: let serverId, channelId: _):
            ServerRoleManager.shared.queryServerRole(serverId: serverId) { role in
                self.role = role
                switch role {
                case .owner, .moderator:
                    self.loadMuteList()
                default:
                    break
                }
            }
        }
        
        EMClient.shared().circleManager?.add(serverDelegate: self, queue: nil)
        EMClient.shared().circleManager?.add(channelDelegate: self, queue: nil)
        EMClient.shared().addMultiDevices(delegate: self, queue: nil)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.navigationController?.setNavigationBarHidden(false, animated: true)
    }
    
    private func loadDataFinish(result: EMCursorResult<EMCircleUser>?, error: EMError?, refresh: Bool) {
        if let error = error {
            Toast.show(error.errorDescription, duration: 2)
            self.tableView.mj_header?.endRefreshing()
            self.tableView.mj_footer?.endRefreshing()
            self.tableView.mj_footer?.isHidden = false
            return
        }
        var userIds: [String] = []
        if let list = result?.list {
            for i in list {
                userIds.append(i.userId)
            }
        }
        if refresh || self.result == nil {
            self.result = result
        } else if let result = result {
            self.result?.append(result)
        }
        self.tableView.mj_header?.endRefreshing()
        if (result?.list?.count ?? 0) < 20 {
            self.tableView.mj_footer?.endRefreshingWithNoMoreData()
            self.tableView.mj_footer?.isHidden = true
        } else {
            self.tableView.mj_footer?.endRefreshing()
            self.tableView.mj_footer?.isHidden = false
        }
        self.tableView.reloadData()
        self.userOnlineStateCache.refresh(members: userIds) { [weak self] in
            self?.tableView.reloadData()
        }
        UserInfoManager.share.queryUserInfo(userIds: userIds) { [weak self] in
            self?.tableView.reloadData()
        }
    }
    
    private func loadData(refresh: Bool) {
        let cursor = refresh ? nil : self.result?.cursor
        switch self.showType {
        case .server(serverId: let serverId):
            EMClient.shared().circleManager?.fetchServerMembers(serverId, limit: 20, cursor: cursor) { result, error in
                self.loadDataFinish(result: result, error: error, refresh: refresh)
            }
        case .channel(serverId: let serverId, channelId: let channelId):
            EMClient.shared().circleManager?.fetchChannelMembers(serverId, channelId: channelId, limit: 20, cursor: cursor, completion: { result, error in
                self.loadDataFinish(result: result, error: error, refresh: refresh)
            })
        }
    }
    
    private func loadMuteList() {
        switch self.showType {
        case .channel(serverId: let serverId, channelId: let channelId):
            EMClient.shared().circleManager?.fetchChannelMuteUsers(serverId, channelId: channelId, completion: { result, error in
                if let error = error {
                    Toast.show(error.errorDescription, duration: 2)
                } else {
                    self.muteStateMap = result
                    self.tableView.reloadData()
                }
            })
        default:
            break
        }
    }
    
    private func removeMembers(members: [String]) {
        guard var list = self.result?.list else {
            return
        }
        var memberSet = Set<String>()
        for member in members {
            memberSet.insert(member)
        }
        var deleteIndexPaths: [IndexPath] = []
        for i in (0..<list.count).reversed() {
            let userId = list[i].userId
            if memberSet.contains(userId) {
                list.remove(at: i)
                deleteIndexPaths.append(IndexPath(row: i, section: 0))
                if members.count == deleteIndexPaths.count {
                    break
                }
            }
        }
        self.result?.list = list
        if deleteIndexPaths.count > 0 {
            self.tableView.performBatchUpdates {
                self.tableView.deleteRows(at: deleteIndexPaths, with: .none)
            }
        }
    }
    
    deinit {
        EMClient.shared().circleManager?.remove(serverDelegate: self)
        EMClient.shared().circleManager?.remove(channelDelegate: self)
        EMClient.shared().remove(self)
    }
}

extension ServerMemberListViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.result?.list?.count ?? 0
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        cell.backgroundColor = .clear
        if let cell = cell as? ServerMemberTableViewCell {
            let member = self.result?.list?[indexPath.row] as? EMCircleUser
            if let userId = member?.userId {
                cell.setUserInfo(userId: userId, userInfo: UserInfoManager.share.userInfo(userId: userId), member: member)
                cell.state = self.userOnlineStateCache.getUserStatus(userId) ?? .offline
            }
        }
        return cell
    }
}

extension ServerMemberListViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let userInfo = self.result?.list?[indexPath.row] as? EMCircleUser, let role = self.role, userInfo.userId != EMClient.shared().currentUsername else {
            return
        }
        let onlineState = self.userOnlineStateCache.getUserStatus(userInfo.userId) ?? .offline
        let vc: ServerUserMenuViewController
        switch self.showType {
        case .server(serverId: let serverId):
            vc = ServerUserMenuViewController(userId: userInfo.userId, showType: .server(serverId: serverId), role: role, targetRole: userInfo.role, onlineState: onlineState)
        case .channel(serverId: let serverId, channelId: let channelId):
            vc = ServerUserMenuViewController(userId: userInfo.userId, showType: .channel(serverId: serverId, channelId: channelId), role: role, targetRole: userInfo.role, onlineState: onlineState, isMute: self.isMute(userId: userInfo.userId))
            vc.didMuteHandle = { userId, duration in
                if let duration = duration {
                    let number = (TimeInterval(duration) + Date().timeIntervalSince1970) * 1000
                    self.muteStateMap?[userId] = NSNumber(value: number)
                } else {
                    self.muteStateMap?[userId] = nil
                }
                if let list = self.result?.list {
                    for i in 0..<list.count where list[i].userId == userId {
                        self.tableView.performBatchUpdates {
                            self.tableView.reloadRows(at: [indexPath], with: .none)
                        }
                        break
                    }
                }
            }
        }
        vc.didRoleChangeHandle = { userId, role in
            if let list = self.result?.list {
                for i in 0..<list.count where list[i].userId == userId {
                    list[i].role = role
                    self.tableView.performBatchUpdates {
                        self.tableView.reloadRows(at: [indexPath], with: .none)
                    }
                    break
                }
            }
        }
        vc.didKickHandle = { userId in
            self.removeMembers(members: [userId])
        }
        self.present(vc, animated: true)
    }
    
    private func isMute(userId: String) -> Bool {
        if let duration = self.muteStateMap?[userId], TimeInterval(duration.uint64Value) / 1000 > Date().timeIntervalSince1970 {
            return true
        } else {
            return false
        }
    }
}

extension ServerMemberListViewController: EMCircleManagerServerDelegate {
    func onServerDestroyed(_ serverId: String, initiator: String) {
        switch self.showType {
        case .server(serverId: let sId):
            if serverId == sId {
                Toast.show("社区被解散", duration: 2)
                self.dismiss(animated: true)
            }
        default:
            break
        }
    }
    
    func onMemberLeftServer(_ serverId: String, member: String) {
        switch self.showType {
        case .server(serverId: let sId):
            if serverId == sId {
                self.removeMembers(members: [member])
            }
        default:
            break
        }
    }
    
    func onMemberRemoved(fromServer serverId: String, members: [String]) {
        guard let current = EMClient.shared().currentUsername else {
            return
        }
        switch self.showType {
        case .server(serverId: let sId):
            if serverId == sId {
                if members.contains(current) {
                    Toast.show("你已被踢出社区", duration: 2)
                    self.dismiss(animated: true)
                } else {
                    self.removeMembers(members: members)
                }
            }
        default:
            break
        }
    }
}

extension ServerMemberListViewController: EMCircleManagerChannelDelegate {
    func onChannelDestroyed(_ serverId: String, channelId: String, initiator: String) {
        switch self.showType {
        case .channel(serverId: let sId, channelId: let cId):
            if serverId == sId, channelId == cId {
                Toast.show("频道被解散", duration: 2)
                self.dismiss(animated: true)
            }
        default:
            break
        }
    }
    
    func onMemberLeftChannel(_ serverId: String, channelId: String, member: String) {
        switch self.showType {
        case .channel(serverId: let sId, channelId: let cId):
            if serverId == sId, channelId == cId {
                self.removeMembers(members: [member])
            }
        default:
            break
        }
    }
    
    func onMemberRemoved(fromChannel serverId: String, channelId: String, member: String, initiator: String) {
        switch self.showType {
        case .channel(serverId: let sId, channelId: let cId):
            if serverId == sId, channelId == cId {
                if member == EMClient.shared().currentUsername {
                    Toast.show("你已被踢出频道", duration: 2)
                    self.dismiss(animated: true)
                } else {
                    self.removeMembers(members: [member])
                }
            }
        default:
            break
        }
    }
    
    func onMemberMuteChange(inChannel serverId: String, channelId: String, muted isMuted: Bool, members: [String]) {
        switch self.showType {
        case .channel(serverId: let sId, channelId: let cId):
            if serverId == sId, channelId == cId {
                self.loadMuteList()
            }
        default:
            break
        }
    }
}

extension ServerMemberListViewController: EMMultiDevicesDelegate {
    func multiDevicesCircleServerEventDidReceive(_ aEvent: EMMultiDevicesEvent, serverId aServerId: String, ext aExt: Any?) {
        switch self.showType {
        case .server(serverId: let sId):
            if aServerId != sId {
                return
            }
        default:
            return
        }
        switch aEvent {
        case .circleServerRemoveUser:
            if let members = aExt as? [String] {
                self.removeMembers(members: members)
            }
        case .circleServerDestroy:
            Toast.show("社区被解散", duration: 2)
            self.dismiss(animated: true)
        case .circleServerExit:
            Toast.show("你已离开社区", duration: 2)
            self.dismiss(animated: true)
        default:
            break
        }
    }
    
    func multiDevicesCircleChannelEventDidReceive(_ aEvent: EMMultiDevicesEvent, channelId aChannelId: String, ext aExt: Any?) {
        switch self.showType {
        case .channel(serverId: _, channelId: let cId):
            if aChannelId != cId {
                return
            }
        default:
            return
        }
        switch aEvent {
        case .circleChannelRemoveUser:
            if let members = aExt as? [String] {
                self.removeMembers(members: members)
            }
        case .circleChannelDestroy:
            Toast.show("频道被解散", duration: 2)
            self.dismiss(animated: true)
        case .circleChannelExit:
            Toast.show("你已离开频道", duration: 2)
            self.dismiss(animated: true)
        case .circleChannelAddMute, .circleChannelRemoveMute:
            self.loadMuteList()
        default:
            break
        }
    }
}